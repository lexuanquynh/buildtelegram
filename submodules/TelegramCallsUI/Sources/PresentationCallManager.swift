import Foundation
import AsyncDisplayKit
import Postbox
import TelegramCore
import SyncCore
import SwiftSignalKit
import Display
import DeviceAccess
import TelegramPresentationData
import TelegramAudio
import TelegramVoip
import TelegramUIPreferences
import AccountContext
import CallKit

private func callKitIntegrationIfEnabled(_ integration: CallKitIntegration?, settings: VoiceCallSettings?) -> CallKitIntegration?  {
    let enabled = settings?.enableSystemIntegration ?? true
    return enabled ? integration : nil
}

private func shouldEnableStunMarking(appConfiguration: AppConfiguration) -> Bool {
    guard let data = appConfiguration.data else {
        return true
    }
    guard let enableStunMarking = data["voip_enable_stun_marking"] as? Bool else {
        return true
    }
    return enableStunMarking
}

private enum CurrentCall {
    case none
    case incomingRinging(CallSessionRingingState)
    case ongoing(CallSession, OngoingCallContext)
    
    var internalId: CallSessionInternalId? {
        switch self {
            case .none:
                return nil
            case let .incomingRinging(ringingState):
                return ringingState.id
            case let .ongoing(session, _):
                return session.id
        }
    }
}

public final class PresentationCallManagerImpl: PresentationCallManager {
    private let getDeviceAccessData: () -> (presentationData: PresentationData, present: (ViewController, Any?) -> Void, openSettings: () -> Void)
    private let isMediaPlaying: () -> Bool
    private let resumeMediaPlayback: () -> Void

    private let accountManager: AccountManager
    private let audioSession: ManagedAudioSession
    private let callKitIntegration: CallKitIntegration?
    
    private var currentCallValue: PresentationCallImpl?
    private var currentCall: PresentationCallImpl? {
        return self.currentCallValue
    }
    private var currentCallDisposable = MetaDisposable()
    private let removeCurrentCallDisposable = MetaDisposable()
    private let removeCurrentGroupCallDisposable = MetaDisposable()
    
    private var currentGroupCallValue: PresentationGroupCallImpl?
    private var currentGroupCall: PresentationGroupCallImpl? {
        return self.currentGroupCallValue
    }
    
    private var ringingStatesDisposable: Disposable?
    
    private let hasActivePersonalCallsPromise = ValuePromise<Bool>(false, ignoreRepeated: true)
    private let hasActiveGroupCallsPromise = ValuePromise<Bool>(false, ignoreRepeated: true)
    public var hasActiveCalls: Signal<Bool, NoError> {
        return combineLatest(queue: .mainQueue(),
            self.hasActivePersonalCallsPromise.get(),
            self.hasActiveGroupCallsPromise.get()
        )
        |> map { value1, value2 -> Bool in
            return value1 || value2
        }
        |> distinctUntilChanged
    }
    
    public var hasActiveCall: Bool {
        return self.currentCall != nil || self.currentGroupCall != nil
    }
    
    private let currentCallPromise = Promise<PresentationCall?>(nil)
    public var currentCallSignal: Signal<PresentationCall?, NoError> {
        return self.currentCallPromise.get()
    }
    
    private let currentGroupCallPromise = Promise<PresentationGroupCall?>(nil)
    public var currentGroupCallSignal: Signal<PresentationGroupCall?, NoError> {
        return self.currentGroupCallPromise.get()
    }
    
    private let startCallDisposable = MetaDisposable()
    
    private var proxyServer: ProxyServerSettings?
    private var proxyServerDisposable: Disposable?
    
    private var callSettings: VoiceCallSettings?
    private var callSettingsDisposable: Disposable?
    
    private var resumeMedia: Bool = false
    
    public static var voipMaxLayer: Int32 {
        return OngoingCallContext.maxLayer
    }
    
    public static func voipVersions(includeExperimental: Bool, includeReference: Bool) -> [(version: String, supportsVideo: Bool)] {
        return OngoingCallContext.versions(includeExperimental: includeExperimental, includeReference: includeReference)
    }
    
    public init(accountManager: AccountManager, getDeviceAccessData: @escaping () -> (presentationData: PresentationData, present: (ViewController, Any?) -> Void, openSettings: () -> Void), isMediaPlaying: @escaping () -> Bool, resumeMediaPlayback: @escaping () -> Void, audioSession: ManagedAudioSession, activeAccounts: Signal<[Account], NoError>) {
        self.getDeviceAccessData = getDeviceAccessData
        self.accountManager = accountManager
        self.audioSession = audioSession
        
        self.isMediaPlaying = isMediaPlaying
        self.resumeMediaPlayback = resumeMediaPlayback
        
        var startCallImpl: ((Account, UUID, String, Bool) -> Signal<Bool, NoError>)?
        var answerCallImpl: ((UUID) -> Void)?
        var endCallImpl: ((UUID) -> Signal<Bool, NoError>)?
        var setCallMutedImpl: ((UUID, Bool) -> Void)?
        var audioSessionActivationChangedImpl: ((Bool) -> Void)?
        
        self.callKitIntegration = CallKitIntegration(startCall: { account, uuid, handle, isVideo in
            if let startCallImpl = startCallImpl {
                return startCallImpl(account, uuid, handle, isVideo)
            } else {
                return .single(false)
            }
        }, answerCall: { uuid in
            answerCallImpl?(uuid)
        }, endCall: { uuid in
            if let endCallImpl = endCallImpl {
                return endCallImpl(uuid)
            } else {
                return .single(false)
            }
        }, setCallMuted: { uuid, isMuted in
            setCallMutedImpl?(uuid, isMuted)
        }, audioSessionActivationChanged: { value in
            audioSessionActivationChangedImpl?(value)
        })
        
        let enableCallKit = accountManager.sharedData(keys: [ApplicationSpecificSharedDataKeys.voiceCallSettings])
        |> map { sharedData -> Bool in
            let settings = sharedData.entries[ApplicationSpecificSharedDataKeys.voiceCallSettings] as? VoiceCallSettings ?? .defaultSettings
            return settings.enableSystemIntegration
        }
        |> distinctUntilChanged
        
        let enabledMicrophoneAccess = Signal<Bool, NoError> { subscriber in
            subscriber.putNext(DeviceAccess.isMicrophoneAccessAuthorized() == true)
            subscriber.putCompletion()
            return EmptyDisposable
        }
        |> runOn(Queue.mainQueue())
        
        let ringingStatesByAccount: Signal<[(Account, CallSessionRingingState, NetworkType)], NoError> = activeAccounts
        |> mapToSignal { accounts -> Signal<[(Account, CallSessionRingingState, NetworkType)], NoError> in
            return combineLatest(accounts.map { account -> Signal<(Account, [CallSessionRingingState], NetworkType), NoError> in
                return combineLatest(account.callSessionManager.ringingStates(), account.networkType)
                |> map { ringingStates, networkType -> (Account, [CallSessionRingingState], NetworkType) in
                    return (account, ringingStates, networkType)
                }
            })
            |> map { ringingStatesByAccount -> [(Account, CallSessionRingingState, NetworkType)] in
                var result: [(Account, CallSessionRingingState, NetworkType)] = []
                for (account, states, networkType) in ringingStatesByAccount {
                    for state in states {
                        result.append((account, state, networkType))
                    }
                }
                return result
            }
        }
        
        self.ringingStatesDisposable = (combineLatest(ringingStatesByAccount, enableCallKit, enabledMicrophoneAccess)
        |> mapToSignal { ringingStatesByAccount, enableCallKit, enabledMicrophoneAccess -> Signal<([(Account, Peer, CallSessionRingingState, Bool, NetworkType)], Bool), NoError> in
            if ringingStatesByAccount.isEmpty {
                return .single(([], enableCallKit && enabledMicrophoneAccess))
            } else {
                return combineLatest(ringingStatesByAccount.map { account, state, networkType -> Signal<(Account, Peer, CallSessionRingingState, Bool, NetworkType)?, NoError> in
                    return account.postbox.transaction { transaction -> (Account, Peer, CallSessionRingingState, Bool, NetworkType)? in
                        if let peer = transaction.getPeer(state.peerId) {
                            return (account, peer, state, transaction.isPeerContact(peerId: state.peerId), networkType)
                        } else {
                            return nil
                        }
                    }
                })
                |> map { ringingStatesByAccount -> ([(Account, Peer, CallSessionRingingState, Bool, NetworkType)], Bool) in
                    return (ringingStatesByAccount.compactMap({ $0 }), enableCallKit && enabledMicrophoneAccess)
                }
            }
        }
        |> deliverOnMainQueue).start(next: { [weak self] ringingStates, enableCallKit in
            self?.ringingStatesUpdated(ringingStates, enableCallKit: enableCallKit)
        })
        
        startCallImpl = { [weak self] account, uuid, handle, isVideo in
            if let strongSelf = self, let userId = Int32(handle) {
                return strongSelf.startCall(account: account, peerId: PeerId(namespace: Namespaces.Peer.CloudUser, id: userId), isVideo: isVideo, internalId: uuid)
                |> take(1)
                |> map { result -> Bool in
                    return result
                }
            } else {
                return .single(false)
            }
        }
        
        answerCallImpl = { [weak self] uuid in
            if let strongSelf = self {
                strongSelf.currentCall?.answer()
            }
        }
        
        endCallImpl = { [weak self] uuid in
            if let strongSelf = self, let currentCall = strongSelf.currentCall {
                return currentCall.hangUp()
            } else {
                return .single(false)
            }
        }
        
        setCallMutedImpl = { [weak self] uuid, isMuted in
            if let strongSelf = self, let currentCall = strongSelf.currentCall {
                currentCall.setIsMuted(isMuted)
            }
        }
        
        audioSessionActivationChangedImpl = { [weak self] value in
            if value {
                self?.audioSession.callKitActivatedAudioSession()
            } else {
                self?.audioSession.callKitDeactivatedAudioSession()
            }
        }
        
        self.proxyServerDisposable = (accountManager.sharedData(keys: [SharedDataKeys.proxySettings])
        |> deliverOnMainQueue).start(next: { [weak self] sharedData in
            if let strongSelf = self, let settings = sharedData.entries[SharedDataKeys.proxySettings] as? ProxySettings {
                if settings.enabled && settings.useForCalls {
                    strongSelf.proxyServer = settings.activeServer
                } else {
                    strongSelf.proxyServer = nil
                }
            }
        })
        
        self.callSettingsDisposable = (accountManager.sharedData(keys: [ApplicationSpecificSharedDataKeys.voiceCallSettings])
        |> deliverOnMainQueue).start(next: { [weak self] sharedData in
            if let strongSelf = self {
                strongSelf.callSettings = sharedData.entries[ApplicationSpecificSharedDataKeys.voiceCallSettings] as? VoiceCallSettings ?? .defaultSettings
            }
        })
    }
    
    deinit {
        self.currentCallDisposable.dispose()
        self.ringingStatesDisposable?.dispose()
        self.removeCurrentCallDisposable.dispose()
        self.removeCurrentGroupCallDisposable.dispose()
        self.startCallDisposable.dispose()
        self.proxyServerDisposable?.dispose()
        self.callSettingsDisposable?.dispose()
    }
    
    private func ringingStatesUpdated(_ ringingStates: [(Account, Peer, CallSessionRingingState, Bool, NetworkType)], enableCallKit: Bool) {
        if let firstState = ringingStates.first {
            if self.currentCall == nil && self.currentGroupCall == nil {
                self.currentCallDisposable.set((combineLatest(firstState.0.postbox.preferencesView(keys: [PreferencesKeys.voipConfiguration, ApplicationSpecificPreferencesKeys.voipDerivedState, PreferencesKeys.appConfiguration]) |> take(1), accountManager.sharedData(keys: [SharedDataKeys.autodownloadSettings, ApplicationSpecificSharedDataKeys.experimentalUISettings]) |> take(1))
                |> deliverOnMainQueue).start(next: { [weak self] preferences, sharedData in
                    guard let strongSelf = self else {
                        return
                    }
                    
                    let configuration = preferences.values[PreferencesKeys.voipConfiguration] as? VoipConfiguration ?? .defaultValue
                    let derivedState = preferences.values[ApplicationSpecificPreferencesKeys.voipDerivedState] as? VoipDerivedState ?? .default
                    let autodownloadSettings = sharedData.entries[SharedDataKeys.autodownloadSettings] as? AutodownloadSettings ?? .defaultSettings
                    let experimentalSettings = sharedData.entries[ApplicationSpecificSharedDataKeys.experimentalUISettings] as? ExperimentalUISettings ?? .defaultSettings
                    let appConfiguration = preferences.values[PreferencesKeys.appConfiguration] as? AppConfiguration ?? AppConfiguration.defaultValue
                    
                    let call = PresentationCallImpl(
                        account: firstState.0,
                        audioSession: strongSelf.audioSession,
                        callSessionManager: firstState.0.callSessionManager,
                        callKitIntegration: enableCallKit ? callKitIntegrationIfEnabled(strongSelf.callKitIntegration, settings: strongSelf.callSettings) : nil,
                        serializedData: configuration.serializedData,
                        dataSaving: effectiveDataSaving(for: strongSelf.callSettings, autodownloadSettings: autodownloadSettings),
                        derivedState: derivedState,
                        getDeviceAccessData: strongSelf.getDeviceAccessData,
                        initialState: nil,
                        internalId: firstState.2.id,
                        peerId: firstState.2.peerId,
                        isOutgoing: false,
                        peer: firstState.1,
                        proxyServer: strongSelf.proxyServer,
                        auxiliaryServers: [],
                        currentNetworkType: firstState.4,
                        updatedNetworkType: firstState.0.networkType,
                        startWithVideo: firstState.2.isVideo,
                        isVideoPossible: firstState.2.isVideoPossible,
                        enableStunMarking: shouldEnableStunMarking(appConfiguration: appConfiguration),
                        enableTCP: experimentalSettings.enableVoipTcp,
                        preferredVideoCodec: experimentalSettings.preferredVideoCodec
                    )
                    strongSelf.updateCurrentCall(call)
                    strongSelf.currentCallPromise.set(.single(call))
                    strongSelf.hasActivePersonalCallsPromise.set(true)
                    strongSelf.removeCurrentCallDisposable.set((call.canBeRemoved
                    |> deliverOnMainQueue).start(next: { [weak self, weak call] value in
                        if value, let strongSelf = self, let call = call {
                            if strongSelf.currentCall === call {
                                strongSelf.updateCurrentCall(nil)
                                strongSelf.currentCallPromise.set(.single(nil))
                                strongSelf.hasActivePersonalCallsPromise.set(false)
                            }
                        }
                    }))
                }))
            } else {
                for (account, _, state, _, _) in ringingStates {
                    if state.id != self.currentCall?.internalId {
                        account.callSessionManager.drop(internalId: state.id, reason: .busy, debugLog: .single(nil))
                    }
                }
            }
        }
    }
    
    public func requestCall(context: AccountContext, peerId: PeerId, isVideo: Bool, endCurrentIfAny: Bool) -> RequestCallResult {
        let account = context.account

        var alreadyInCall: Bool = false
        var alreadyInCallWithPeerId: PeerId?
        
        if let call = self.currentCall {
            alreadyInCall = true
            alreadyInCallWithPeerId = call.peerId
        } else if let currentGroupCall = self.currentGroupCallValue {
            alreadyInCall = true
            alreadyInCallWithPeerId = currentGroupCall.peerId
        } else {
            if #available(iOS 10.0, *) {
                if CXCallObserver().calls.contains(where: { $0.hasEnded == false }) {
                    alreadyInCall = true
                }
            }
        }
        
        if alreadyInCall, !endCurrentIfAny {
            return .alreadyInProgress(alreadyInCallWithPeerId)
        }
        if let _ = callKitIntegrationIfEnabled(self.callKitIntegration, settings: self.callSettings) {
            let begin: () -> Void = { [weak self] in
                guard let strongSelf = self else {
                    return
                }
                let (presentationData, present, openSettings) = strongSelf.getDeviceAccessData()
                
                let accessEnabledSignal: Signal<Bool, NoError> = Signal { subscriber in
                    DeviceAccess.authorizeAccess(to: .microphone(.voiceCall), presentationData: presentationData, present: { c, a in
                        present(c, a)
                    }, openSettings: {
                        openSettings()
                    }, { value in
                        if isVideo && value {
                            DeviceAccess.authorizeAccess(to: .camera(.videoCall), presentationData: presentationData, present: { c, a in
                                present(c, a)
                            }, openSettings: {
                                openSettings()
                            }, { value in
                                subscriber.putNext(value)
                                subscriber.putCompletion()
                            })
                        } else {
                            subscriber.putNext(value)
                            subscriber.putCompletion()
                        }
                    })
                    return EmptyDisposable
                }
                |> runOn(Queue.mainQueue())
                let postbox = account.postbox
                strongSelf.startCallDisposable.set((accessEnabledSignal
                |> mapToSignal { accessEnabled -> Signal<Peer?, NoError> in
                    if !accessEnabled {
                        return .single(nil)
                    }
                    return postbox.loadedPeerWithId(peerId)
                    |> take(1)
                    |> map(Optional.init)
                }
                |> deliverOnMainQueue).start(next: { peer in
                    guard let strongSelf = self, let peer = peer else {
                        return
                    }
                    strongSelf.callKitIntegration?.startCall(account: account, peerId: peerId, isVideo: isVideo, displayTitle: peer.debugDisplayTitle)
                }))
            }
            if let currentCall = self.currentCall {
                self.callKitIntegration?.dropCall(uuid: currentCall.internalId)
                self.startCallDisposable.set((currentCall.hangUp()
                |> deliverOnMainQueue).start(next: { _ in
                    begin()
                }))
            } else if let currentGroupCall = self.currentGroupCallValue {
                self.startCallDisposable.set((currentGroupCall.leave(terminateIfPossible: false)
                |> filter { $0 }
                |> take(1)
                |> deliverOnMainQueue).start(next: { _ in
                    begin()
                }))
            } else {
                begin()
            }
        } else {
            let begin: () -> Void = { [weak self] in
                guard let strongSelf = self else {
                    return
                }
                let _ = strongSelf.startCall(account: account, peerId: peerId, isVideo: isVideo).start()
            }
            if let currentCall = self.currentCall {
                self.startCallDisposable.set((currentCall.hangUp()
                |> deliverOnMainQueue).start(next: { _ in
                    begin()
                }))
            } else if let currentGroupCall = self.currentGroupCallValue {
                self.startCallDisposable.set((currentGroupCall.leave(terminateIfPossible: false)
                |> filter { $0 }
                |> take(1)
                |> deliverOnMainQueue).start(next: { _ in
                    begin()
                }))
            } else {
                begin()
            }
        }
        return .requested
    }
    
    private func startCall(
        account: Account,
        peerId: PeerId,
        isVideo: Bool,
        internalId: CallSessionInternalId = CallSessionInternalId()
    ) -> Signal<Bool, NoError> {
        let (presentationData, present, openSettings) = self.getDeviceAccessData()
        
        let accessEnabledSignal: Signal<Bool, NoError> = Signal { subscriber in
            DeviceAccess.authorizeAccess(to: .microphone(.voiceCall), presentationData: presentationData, present: { c, a in
                present(c, a)
            }, openSettings: {
                openSettings()
            }, { value in
                if isVideo && value {
                    DeviceAccess.authorizeAccess(to: .camera(.videoCall), presentationData: presentationData, present: { c, a in
                        present(c, a)
                    }, openSettings: {
                        openSettings()
                    }, { value in
                        subscriber.putNext(value)
                        subscriber.putCompletion()
                    })
                } else {
                    subscriber.putNext(value)
                    subscriber.putCompletion()
                }
            })
            return EmptyDisposable
        }
        |> runOn(Queue.mainQueue())
        
        let networkType = account.networkType
        let accountManager = self.accountManager
        return accessEnabledSignal
        |> mapToSignal { [weak self] accessEnabled -> Signal<Bool, NoError> in
            if !accessEnabled {
                return .single(false)
            }
            
            let request = account.postbox.transaction { transaction -> (VideoCallsConfiguration, CachedUserData?) in
                let appConfiguration: AppConfiguration = transaction.getPreferencesEntry(key: PreferencesKeys.appConfiguration) as? AppConfiguration ?? AppConfiguration.defaultValue
                return (VideoCallsConfiguration(appConfiguration: appConfiguration), transaction.getPeerCachedData(peerId: peerId) as? CachedUserData)
            }
            |> mapToSignal { callsConfiguration, cachedUserData -> Signal<CallSessionInternalId, NoError> in
                var isVideoPossible: Bool
                switch callsConfiguration.videoCallsSupport {
                case .disabled:
                    isVideoPossible = isVideo
                case .full:
                    isVideoPossible = true
                case .onlyVideo:
                    isVideoPossible = isVideo
                }
                if let cachedUserData = cachedUserData, cachedUserData.videoCallsAvailable {
                } else {
                    isVideoPossible = false
                }
                
                return account.callSessionManager.request(peerId: peerId, isVideo: isVideo, enableVideo: isVideoPossible, internalId: internalId)
            }
            
            let cachedUserData = account.postbox.transaction { transaction -> CachedUserData? in
                return transaction.getPeerCachedData(peerId: peerId) as? CachedUserData
            }
            
            return (combineLatest(queue: .mainQueue(), request, networkType |> take(1), account.postbox.peerView(id: peerId) |> map { peerView -> Bool in
                return peerView.peerIsContact
            } |> take(1), account.postbox.preferencesView(keys: [PreferencesKeys.voipConfiguration, ApplicationSpecificPreferencesKeys.voipDerivedState, PreferencesKeys.appConfiguration]) |> take(1), accountManager.sharedData(keys: [SharedDataKeys.autodownloadSettings, ApplicationSpecificSharedDataKeys.experimentalUISettings]) |> take(1), cachedUserData)
            |> deliverOnMainQueue
            |> beforeNext { internalId, currentNetworkType, isContact, preferences, sharedData, cachedUserData in
                if let strongSelf = self, accessEnabled {
                    if let currentCall = strongSelf.currentCall {
                        currentCall.rejectBusy()
                    }
                    
                    let configuration = preferences.values[PreferencesKeys.voipConfiguration] as? VoipConfiguration ?? .defaultValue
                    let derivedState = preferences.values[ApplicationSpecificPreferencesKeys.voipDerivedState] as? VoipDerivedState ?? .default
                    let autodownloadSettings = sharedData.entries[SharedDataKeys.autodownloadSettings] as? AutodownloadSettings ?? .defaultSettings
                    let appConfiguration = preferences.values[PreferencesKeys.appConfiguration] as? AppConfiguration ?? AppConfiguration.defaultValue
                    
                    let callsConfiguration = VideoCallsConfiguration(appConfiguration: appConfiguration)
                    var isVideoPossible: Bool
                    switch callsConfiguration.videoCallsSupport {
                    case .disabled:
                        isVideoPossible = isVideo
                    case .full:
                        isVideoPossible = true
                    case .onlyVideo:
                        isVideoPossible = isVideo
                    }
                    if let cachedUserData = cachedUserData, cachedUserData.videoCallsAvailable {
                    } else {
                        isVideoPossible = false
                    }
                    
                    let experimentalSettings = sharedData.entries[ApplicationSpecificSharedDataKeys.experimentalUISettings] as? ExperimentalUISettings ?? .defaultSettings
                    
                    let call = PresentationCallImpl(
                        account: account,
                        audioSession: strongSelf.audioSession,
                        callSessionManager: account.callSessionManager,
                        callKitIntegration: callKitIntegrationIfEnabled(
                            strongSelf.callKitIntegration,
                            settings: strongSelf.callSettings
                        ),
                        serializedData: configuration.serializedData,
                        dataSaving: effectiveDataSaving(for: strongSelf.callSettings, autodownloadSettings: autodownloadSettings),
                        derivedState: derivedState,
                        getDeviceAccessData: strongSelf.getDeviceAccessData,
                        initialState: nil,
                        internalId: internalId,
                        peerId: peerId,
                        isOutgoing: true,
                        peer: nil,
                        proxyServer: strongSelf.proxyServer,
                        auxiliaryServers: [],
                        currentNetworkType: currentNetworkType,
                        updatedNetworkType: account.networkType,
                        startWithVideo: isVideo,
                        isVideoPossible: isVideoPossible,
                        enableStunMarking: shouldEnableStunMarking(appConfiguration: appConfiguration),
                        enableTCP: experimentalSettings.enableVoipTcp,
                        preferredVideoCodec: experimentalSettings.preferredVideoCodec
                    )
                    strongSelf.updateCurrentCall(call)
                    strongSelf.currentCallPromise.set(.single(call))
                    strongSelf.hasActivePersonalCallsPromise.set(true)
                    strongSelf.removeCurrentCallDisposable.set((call.canBeRemoved
                    |> deliverOnMainQueue).start(next: { [weak call] value in
                        if value, let strongSelf = self, let call = call {
                            if strongSelf.currentCall === call {
                                strongSelf.updateCurrentCall(nil)
                                strongSelf.currentCallPromise.set(.single(nil))
                                strongSelf.hasActivePersonalCallsPromise.set(false)
                            }
                        }
                    }))
                }
            })
            |> mapToSignal { value -> Signal<Bool, NoError> in
                return .single(true)
            }
        }
    }
    
    private func updateCurrentCall(_ value: PresentationCallImpl?) {
        let wasEmpty = self.currentCallValue == nil
        let isEmpty = value == nil
        if wasEmpty && !isEmpty {
            self.resumeMedia = self.isMediaPlaying()
        }
        
        self.currentCallValue = value
        
        if !wasEmpty && isEmpty && self.resumeMedia {
            self.resumeMedia = false
            self.resumeMediaPlayback()
        }
    }
    
    private func updateCurrentGroupCall(_ value: PresentationGroupCallImpl?) {
        let wasEmpty = self.currentGroupCallValue == nil
        let isEmpty = value == nil
        if wasEmpty && !isEmpty {
            self.resumeMedia = self.isMediaPlaying()
        }
        
        self.currentGroupCallValue = value
        
        if !wasEmpty && isEmpty && self.resumeMedia {
            self.resumeMedia = false
            self.resumeMediaPlayback()
        }
    }
    
    public func joinGroupCall(context: AccountContext, peerId: PeerId, invite: String?, requestJoinAsPeerId: ((@escaping (PeerId?) -> Void) -> Void)?, initialCall: CachedChannelData.ActiveCall, endCurrentIfAny: Bool) -> JoinGroupCallManagerResult {
        let begin: () -> Void = { [weak self] in
            if let requestJoinAsPeerId = requestJoinAsPeerId {
                requestJoinAsPeerId({ joinAsPeerId in
                    let _ = self?.startGroupCall(accountContext: context, peerId: peerId, invite: invite, joinAsPeerId: joinAsPeerId, initialCall: initialCall).start()
                })
            } else {
                let _ = self?.startGroupCall(accountContext: context, peerId: peerId, invite: invite, joinAsPeerId: nil, initialCall: initialCall).start()
            }
        }
        
        if let currentGroupCall = self.currentGroupCallValue {
            if endCurrentIfAny {
                let endSignal = currentGroupCall.leave(terminateIfPossible: false)
                |> filter { $0 }
                |> take(1)
                |> deliverOnMainQueue
                self.startCallDisposable.set(endSignal.start(next: { _ in
                    begin()
                }))
            } else {
                return .alreadyInProgress(currentGroupCall.peerId)
            }
        } else if let currentCall = self.currentCall {
            if endCurrentIfAny {
                self.callKitIntegration?.dropCall(uuid: currentCall.internalId)
                self.startCallDisposable.set((currentCall.hangUp()
                |> deliverOnMainQueue).start(next: { _ in
                    begin()
                }))
            } else {
                return .alreadyInProgress(currentCall.peerId)
            }
        } else {
            begin()
        }
        return .joined
    }
    
    private func startGroupCall(
        accountContext: AccountContext,
        peerId: PeerId,
        invite: String?,
        joinAsPeerId: PeerId?,
        initialCall: CachedChannelData.ActiveCall,
        internalId: CallSessionInternalId = CallSessionInternalId()
    ) -> Signal<Bool, NoError> {
        let (presentationData, present, openSettings) = self.getDeviceAccessData()
        
        let isVideo = false
        
        let accessEnabledSignal: Signal<Bool, NoError> = Signal { subscriber in
            DeviceAccess.authorizeAccess(to: .microphone(.voiceCall), presentationData: presentationData, present: { c, a in
                present(c, a)
            }, openSettings: {
                openSettings()
            }, { value in
                if isVideo && value {
                    DeviceAccess.authorizeAccess(to: .camera(.videoCall), presentationData: presentationData, present: { c, a in
                        present(c, a)
                    }, openSettings: {
                        openSettings()
                    }, { value in
                        subscriber.putNext(value)
                        subscriber.putCompletion()
                    })
                } else {
                    subscriber.putNext(value)
                    subscriber.putCompletion()
                }
            })
            return EmptyDisposable
        }
        |> runOn(Queue.mainQueue())
        
        return accessEnabledSignal
        |> deliverOnMainQueue
        |> mapToSignal { [weak self] accessEnabled -> Signal<Bool, NoError> in
            guard let strongSelf = self else {
                return .single(false)
            }
            
            if !accessEnabled {
                return .single(false)
            }
                    
            let call = PresentationGroupCallImpl(
                accountContext: accountContext,
                audioSession: strongSelf.audioSession,
                callKitIntegration: nil,
                getDeviceAccessData: strongSelf.getDeviceAccessData,
                initialCall: initialCall,
                internalId: internalId,
                peerId: peerId,
                invite: invite,
                joinAsPeerId: joinAsPeerId
            )
            strongSelf.updateCurrentGroupCall(call)
            strongSelf.currentGroupCallPromise.set(.single(call))
            strongSelf.hasActiveGroupCallsPromise.set(true)
            strongSelf.removeCurrentGroupCallDisposable.set((call.canBeRemoved
            |> filter { $0 }
            |> take(1)
            |> deliverOnMainQueue).start(next: { [weak call] value in
                guard let strongSelf = self, let call = call else {
                    return
                }
                if value {
                    if strongSelf.currentGroupCall === call {
                        strongSelf.updateCurrentGroupCall(nil)
                        strongSelf.currentGroupCallPromise.set(.single(nil))
                        strongSelf.hasActiveGroupCallsPromise.set(false)
                    }
                }
            }))
        
            return .single(true)
        }
    }
}
