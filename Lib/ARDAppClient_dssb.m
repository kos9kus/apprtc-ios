/*
 * libjingle
 * Copyright 2014, Google Inc.
 *
 * Redistribution and use in source and binary forms, with or without
 * modification, are permitted provided that the following conditions are met:
 *
 *  1. Redistributions of source code must retain the above copyright notice,
 *     this list of conditions and the following disclaimer.
 *  2. Redistributions in binary form must reproduce the above copyright notice,
 *     this list of conditions and the following disclaimer in the documentation
 *     and/or other materials provided with the distribution.
 *  3. The name of the author may not be used to endorse or promote products
 *     derived from this software without specific prior written permission.
 *
 * THIS SOFTWARE IS PROVIDED BY THE AUTHOR ``AS IS'' AND ANY EXPRESS OR IMPLIED
 * WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED WARRANTIES OF
 * MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO
 * EVENT SHALL THE AUTHOR BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL,
 * SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO,
 * PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS;
 * OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY,
 * WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR
 * OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF
 * ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
 */

#import "ARDAppClient.h"

#import <AVFoundation/AVFoundation.h>

#import "ARDMessageResponse.h"
#import "ARDRegisterResponse.h"
#import "ARDSignalingMessage.h"
#import "ARDUtilities.h"
#import "ARDWebSocketChannel.h"
#import "RTCICECandidate+JSON.h"
#import "RTCICEServer+JSON.h"
#import "RTCMediaConstraints.h"
#import "RTCMediaStream.h"
#import "RTCPair.h"
#import "RTCPeerConnection.h"
#import "RTCPeerConnectionDelegate.h"
#import "RTCPeerConnectionFactory.h"
#import "RTCSessionDescription+JSON.h"
#import "RTCSessionDescriptionDelegate.h"
#import "RTCVideoCapturer.h"
#import "RTCVideoTrack.h"

#ifdef DEBUG
//#import "NamesAccessibilityTesting.h"
#endif


//static NSString *kARDAppClientErrorDomain = @"ARDAppClient";

@interface ARDAppClient () < RTCPeerConnectionDelegate, RTCSessionDescriptionDelegate >
{
    RTCSessionDescription* remoteAnswerSdp;
    RTCICEGatheringState _ICECandidateGatheringState;
    
    NSMutableArray * localIceCndidates;
    
    UIDeviceOrientation currentOrientation;
    BOOL isForeGround;
    AVCaptureSession* sessionCurrent;
    AVCaptureDevicePosition cameraPosition;
    BOOL isCanRotate;
}
@property(nonatomic, strong) ARDWebSocketChannel *channel;

@property(nonatomic, strong) RTCPeerConnectionFactory *factory;
@property(nonatomic, strong) NSMutableArray *messageQueue;

@property(nonatomic, assign) BOOL isTurnComplete;
@property(nonatomic, assign) BOOL hasReceivedSdp;
@property(nonatomic, readonly) BOOL isRegisteredWithRoomServer;

@property(nonatomic, strong) NSString *roomId;
@property(nonatomic, strong) NSString *clientId;
@property(nonatomic, assign) BOOL isInitiator;
@property(nonatomic, assign) BOOL isSpeakerEnabled;
@property(nonatomic, strong) NSMutableArray *iceServers;
@property(nonatomic, strong) NSURL *webSocketURL;
@property(nonatomic, strong) NSURL *webSocketRestURL;
@property(nonatomic, strong) RTCAudioTrack *defaultAudioTrack;
@property(nonatomic, strong) RTCVideoTrack *defaultVideoTrack;

@end

@implementation ARDAppClient

@synthesize delegate = _delegate;
@synthesize state = _state;
@synthesize serverHostUrl = _serverHostUrl;
@synthesize channel = _channel;
@synthesize peerConnection = _peerConnection;
@synthesize factory = _factory;
@synthesize messageQueue = _messageQueue;
@synthesize isTurnComplete = _isTurnComplete;
@synthesize hasReceivedSdp  = _hasReceivedSdp;
@synthesize roomId = _roomId;
@synthesize clientId = _clientId;
@synthesize isInitiator = _isInitiator;
@synthesize isSpeakerEnabled = _isSpeakerEnabled;
@synthesize iceServers = _iceServers;
@synthesize webSocketURL = _websocketURL;
@synthesize webSocketRestURL = _websocketRestURL;

- (instancetype)initWithDelegate:(id<ARDAppClientDelegate>)delegate {
    if (self = [super init]) {
        _delegate = delegate;
        _factory = [[RTCPeerConnectionFactory alloc] init];
        _messageQueue = [NSMutableArray array];
        localIceCndidates = [NSMutableArray array];
        _iceServers = [self defaultDSSBSTUNServer];
        currentOrientation = [[UIDevice currentDevice] orientation];
        isForeGround = YES;
        _isSpeakerEnabled = NO;
        cameraPosition = AVCaptureDevicePositionFront;
        isCanRotate = NO;

        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(orientationChanged:) name:UIDeviceOrientationDidChangeNotification object:nil];
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(handleCaptureSessionStopRunning:) name:AVCaptureSessionDidStopRunningNotification object:nil];
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(handleStartCaptureSession:) name:AVCaptureSessionDidStartRunningNotification object:nil];

        // Init observers to handle going into fore- and back- ground
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(didEnterBackgroundVideo) name:UIApplicationWillResignActiveNotification object:nil];
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(didEnterForegroundVideo) name:UIApplicationDidBecomeActiveNotification object:nil];
    }
    return self;
}

- (void)dealloc {
#ifdef DEBUG
    NSLog(@"\n\n ===== ARDAppClient dealloc ======== \n\n ");
#endif
    [ [NSNotificationCenter defaultCenter] removeObserver:self name:UIDeviceOrientationDidChangeNotification object:nil];
    [ [NSNotificationCenter defaultCenter] removeObserver:self name:AVCaptureSessionDidStopRunningNotification object:nil ];
    [ [NSNotificationCenter defaultCenter] removeObserver:self name:AVCaptureSessionDidStartRunningNotification object:nil ];
    
    [ [NSNotificationCenter defaultCenter] removeObserver:self name:UIApplicationWillResignActiveNotification object:nil];
    [ [NSNotificationCenter defaultCenter] removeObserver:self name:UIApplicationDidBecomeActiveNotification object:nil ];
    
    [self disconnect];
}

#pragma mark -

- (void)handleCaptureSessionStopRunning:(NSNotification *)notification {
    if ([NSThread isMainThread]) {
        if (isForeGround) {
            [self restoreAllMediaStreams];
        }
    } else {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (isForeGround) {
                [self restoreAllMediaStreams];
            }
        });
    }
}

- (void)handleStartCaptureSession:(NSNotification *)notification {
    sessionCurrent = notification.object;
}

- (void)orientationChanged:(NSNotification *)notification {
    UIDeviceOrientation orientation = [[UIDevice currentDevice] orientation];
    if (orientation == UIDeviceOrientationLandscapeLeft || orientation == UIDeviceOrientationLandscapeRight || orientation == UIDeviceOrientationPortrait) {
        if (currentOrientation == orientation) {
            return;
        }
        currentOrientation = orientation;
        [self cleanUpAllMediaStreams];
    }
}

- (void)didEnterForegroundVideo {
    isForeGround = YES;
    [self restoreAllMediaStreams];
}

- (void)didEnterBackgroundVideo {
    isForeGround = NO;
    [self cleanUpAllMediaStreams];
}

- (void)restoreAllMediaStreams {
    if (self.peerConnection && _peerConnection.localStreams.count == 0){
        RTCMediaStream* localStream = [self createLocalMediaStream];
        [self.peerConnection addStream:localStream];
    }
}

-(void)cleanUpAllMediaStreams {
    //Remove current video track
    if (_peerConnection.localStreams.count == 0) {
        return;
    }
    RTCMediaStream *localStream = _peerConnection.localStreams[0];
    if (localStream.videoTracks.count == 0) {
        return;
    }
    [localStream removeVideoTrack:localStream.videoTracks[0]];
    
    if (localStream.audioTracks.count > 0) {
        RTCAudioTrack* formerAudioTrack = localStream.audioTracks[0];
        [localStream removeAudioTrack:formerAudioTrack];
    }
    
    [_peerConnection removeStream:localStream];
    if (sessionCurrent) {
        [sessionCurrent stopRunning];
    }
}


- (void)setState:(ARDAppClientState)state {
    if (_state == state) {
        return;
    }
    _state = state;
    if ([_delegate respondsToSelector:@selector(appClient:didChangeState:)] ) {
        [_delegate appClient:self didChangeState:_state];
    }
}

- (void)disconnect {
    if (_state == kARDAppClientStateDisconnected) {
        return;
    }
    
    sessionCurrent = nil;
    [self didEnterBackgroundVideo];
    
    _clientId = nil;
    _roomId = nil;
    _isInitiator = NO;
    _hasReceivedSdp = NO;
    _messageQueue = [NSMutableArray array];
    _peerConnection = nil;
    self.state = kARDAppClientStateDisconnected;
}


#pragma mark - RTCPeerConnectionDelegate

- (void)peerConnection:(RTCPeerConnection *)peerConnection didOpenDataChannel:(RTCDataChannel *)dataChannel
{}

- (void)peerConnection:(RTCPeerConnection *)peerConnection signalingStateChanged:(RTCSignalingState)stateChanged {
    
    switch (stateChanged) {
        case RTCSignalingStable:
            NSLog(@"Signaling state changed: RTCSignalingStable");
            break;
        case RTCSignalingHaveLocalOffer:
            NSLog(@"Signaling state changed: RTCSignalingHaveLocalOffer");
            break;
        case RTCSignalingHaveRemoteOffer:
            NSLog(@"Signaling state changed: RTCSignalingHaveRemoteOffer");
            break;
        case RTCSignalingHaveLocalPrAnswer:
            NSLog(@"Signaling state changed: RTCSignalingHaveLocalPrAnswer");
            break;
        case RTCSignalingHaveRemotePrAnswer:
            NSLog(@"Signaling state changed: RTCSignalingHaveRemotePrAnswer");
            break;
        case RTCSignalingClosed:
            NSLog(@"Signaling state changed: RTCSignalingClosed");
            break;
        default:
            NSLog( @"Signaling state changed: %d", stateChanged );
            break;
    }
}

- (void)peerConnection:(RTCPeerConnection *)peerConnection addedStream:(RTCMediaStream *)stream {
    dispatch_async(dispatch_get_main_queue(), ^{
        
        NSLog(@"Received %lu video tracks and %lu audio tracks",
              (unsigned long)stream.videoTracks.count,
              (unsigned long)stream.audioTracks.count);
        
        if (stream.videoTracks.count) {
            RTCVideoTrack *videoTrack = stream.videoTracks[0];
            [_delegate appClient:self didReceiveRemoteVideoTrack:videoTrack];
        }
    });
}

- (void)peerConnection:(RTCPeerConnection *)peerConnection removedStream:(RTCMediaStream *)stream {
    NSLog(@"Stream was removed.");
}

- (void)peerConnectionOnRenegotiationNeeded:
(RTCPeerConnection *)peerConnection {
    NSLog(@"WARNING: Renegotiation needed but unimplemented.");
}

- (void)peerConnection:(RTCPeerConnection *)peerConnection iceConnectionChanged:(RTCICEConnectionState)newState {
    
    switch (newState) {
        case RTCICEConnectionNew:
            NSLog(@"ICE state changed: RTCICEConnectionNew");
            break;
        case RTCICEConnectionChecking:
            NSLog(@"ICE state changed: RTCICEConnectionChecking");
            break;
        case RTCICEConnectionConnected:
            NSLog(@"ICE state changed: RTCICEConnectionConnected");
            isCanRotate = YES;
            if (self.isInitiator) {
                [self cleanUpAllMediaStreams];
            }
            [self.delegate appClientIceConnectionCompleted:self];
            break;
        case RTCICEConnectionCompleted:
            NSLog(@"ICE state changed: RTCICEConnectionCompleted");
            break;
        case RTCICEConnectionFailed:
            NSLog(@"ICE state changed: RTCICEConnectionFailed");
            break;
        case RTCICEConnectionDisconnected:
            NSLog(@"ICE state changed: RTCICEConnectionDisconnected");
            break;
        case RTCICEConnectionClosed:
            NSLog(@"ICE state changed: RTCICEConnectionClosed");
            break;
        default:
            NSLog(@"ICE state changed: %d", newState);
            break;
    }
}

- (void)peerConnection:(RTCPeerConnection *)peerConnection   iceGatheringChanged:(RTCICEGatheringState)newState {
    
    dispatch_async(dispatch_get_main_queue(), ^{
        
        switch (newState) {
            case RTCICEGatheringGathering:
                NSLog(@"ICE gathering state changed: RTCICEGatheringGathering");
                _ICECandidateGatheringState = newState;
                break;
            case RTCICEGatheringComplete:{
                NSLog(@"ICE gathering state changed: RTCICEGatheringComplete");
                
                _ICECandidateGatheringState = newState;
                
                [self drainMessageQueueIfReady];
                [self sendAllGatheredLocalIceCandidates];
            }
                break;
            default:
                NSLog(@"ICE gathering state changed: %d", newState);
                break;
        }
        
    });
}

- (void)peerConnection:(RTCPeerConnection *)peerConnection gotICECandidate:(RTCICECandidate *)candidate {
    dispatch_async(dispatch_get_main_queue(), ^{
        
        NSLog(@"\n GotICECandidate: %@ == %@", candidate.description, candidate); // 48 items of all
        
        NSString* strOfJSONData = [NSString stringWithFormat:@"{\"candidate\":\"%@\",\"sdpMid\":\"%@\",\"sdpMLineIndex\":%@}", candidate.sdp, candidate.sdpMid, @(candidate.sdpMLineIndex)];
        ARDICECandidateMessage *message = [[ARDICECandidateMessage alloc] initWithCandidate:candidate];
        
        if(_ICECandidateGatheringState == RTCICEGatheringGathering)
            [localIceCndidates addObject:@[message, strOfJSONData] ];
    });
}

#pragma mark - RTCSessionDescriptionDelegate

- (void)peerConnection:(RTCPeerConnection *)peerConnection
didCreateSessionDescription:(RTCSessionDescription *)sdp
                 error:(NSError *)error {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (error) {
            NSLog(@"Failed to create session description. Error: %@", error);
            NSDictionary *userInfo = @{
                                       NSLocalizedDescriptionKey: @"Failed to create session description.",
                                       };
            
            NSError* errorOutput = [[NSError alloc] initWithDomain:error.domain
                                                              code:error.code
                                                          userInfo:userInfo];
#ifdef DEBUG
            //            [ [NSNotificationCenter defaultCenter] postNotificationName:TestNotificationNameFailedCreateDesciption object:nil];
#endif
            [self emergeError:errorOutput];
            return;
        }
        
        [_peerConnection setLocalDescriptionWithDelegate:self sessionDescription:sdp];
        
        ARDSessionDescriptionMessage *message =  [ [ARDSessionDescriptionMessage alloc] initWithDescription:sdp];
        
        [self sendSignalingMessageDSSB:message];
    });
}

- (void)peerConnection:(RTCPeerConnection *)peerConnection
didSetSessionDescriptionWithError:(NSError *)error {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (error) {
            NSLog(@"Failed to set session description. Error: %@", error);
            
#ifdef DEBUG
            //            [ [NSNotificationCenter defaultCenter] postNotificationName:TestNotificationNameFailedSetVideoSession object:nil];
#endif
            [self emergeError:error];
            return;
        }
        // If we're answering and we've just set the remote offer we need to create
        // an answer and set the local description.
        if ( !_peerConnection.localDescription )
        {
            if (!_isInitiator)
            {
                RTCMediaConstraints *constraints = [self defaultAnswerConstraints];
                [_peerConnection createAnswerWithDelegate:self
                                              constraints:constraints];
            }
        }
        
        [self sendAllGatheredLocalIceCandidates];
    });
}

#pragma mark - DSSBCustom Methods

- (void)connectToRoomWithIdDSSBWithJsonDictionary:(NSDictionary*)message
{
    NSParameterAssert(_state == kARDAppClientStateDisconnected);
    self.state = kARDAppClientStateConnecting;
    
    // Create peer connection.
    RTCMediaConstraints *constraints = [self defaultPeerConnectionConstraints];
    
    _peerConnection = [_factory peerConnectionWithICEServers:_iceServers constraints:constraints delegate:self];
    RTCMediaStream *localStream = [self createLocalMediaStream];
    [_peerConnection addStream:localStream];
    
    self.state = kARDAppClientStateConnected;
    
    ARDSignalingMessage *messageSignaling = nil;
    if ( !message ) {
        self.isInitiator = YES;
        [self sendOffer];
    }
    else {
        messageSignaling = [ARDSignalingMessage messageFromNSDictionaryDSSB:message];
        _hasReceivedSdp = YES;
        [self processSignalingMessage:messageSignaling ];
        
    }
}

-(void)addNewICECandidate:(NSDictionary*)message
{
    ARDSignalingMessage *messageSignaling = [ARDSignalingMessage messageFromNSDictionaryDSSB:message];
    
    switch (messageSignaling.type) {
        case kARDSignalingMessageTypeOffer:
        case kARDSignalingMessageTypeAnswer:{
            if ( !_hasReceivedSdp ) {
                _hasReceivedSdp = YES;
                
                [self.messageQueue insertObject:messageSignaling atIndex:0];
            }
        }
            break;
        case kARDSignalingMessageTypeCandidate:
            [_messageQueue addObject:messageSignaling];
            break;
        case kARDSignalingMessageTypeBye:
            return;
    }
    [self drainMessageQueueIfReady];
}


- (void)sendSignalingMessageDSSB:(ARDSignalingMessage *)message {
    [self sendSignalingMessageDSSBWithMessage:message];
}


- (NSMutableArray*)defaultDSSBSTUNServer
{
    NSMutableArray* arrICEServers = [NSMutableArray array];
    
    NSURL *defaultSTUNServerURL1 = [NSURL URLWithString:@"stun:proxy-useast.starpoundtech.net:443"];
    [arrICEServers addObject: [[RTCICEServer alloc] initWithURI:defaultSTUNServerURL1
                                                       username:@""
                                                       password:@""] ];
    NSURL *defaultSTUNServerURL2 = [NSURL URLWithString:@"stun:stun.l.google.com:19302"];
    [arrICEServers addObject: [[RTCICEServer alloc] initWithURI:defaultSTUNServerURL2
                                                       username:@""
                                                       password:@""] ];
    NSURL *defaultSTUNServerURL3 = [NSURL URLWithString:@"stun:stun1.l.google.com:19302"];
    [arrICEServers addObject: [[RTCICEServer alloc] initWithURI:defaultSTUNServerURL3
                                                       username:@""
                                                       password:@""] ];
    NSURL *defaultSTUNServerURL4 = [NSURL URLWithString:@"stun:stun2.l.google.com:19302"];
    [arrICEServers addObject: [[RTCICEServer alloc] initWithURI:defaultSTUNServerURL4
                                                       username:@""
                                                       password:@""] ];
    NSURL *defaultSTUNServerURL5 = [NSURL URLWithString:@"stun:stun3.l.google.com:19302"];
    [arrICEServers addObject: [[RTCICEServer alloc] initWithURI:defaultSTUNServerURL5
                                                       username:@""
                                                       password:@""] ];
    NSURL *defaultSTUNServerURL6 = [NSURL URLWithString:@"stun:stun4.l.google.com:19302"];
    [arrICEServers addObject: [[RTCICEServer alloc] initWithURI:defaultSTUNServerURL6
                                                       username:@""
                                                       password:@""] ];
    NSURL *defaultSTUNServerURL7 = [NSURL URLWithString:@"turn:proxy-useast.starpoundtech.net:443?transport=tcp"];
    
    [arrICEServers addObject: [[RTCICEServer alloc] initWithURI:defaultSTUNServerURL7
                                                       username:@"spuser8"
                                                       password:@"98hetu7GT"] ];
    
    return arrICEServers;
}

-(void)sendSignalingMessageDSSBWithMessage:(ARDSignalingMessage *)message {
    NSData *data = [message JSONData];
    NSString* strOfJSONData = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    if ( [self.delegate respondsToSelector:@selector(appClient:withMessage:andBodyMessage:) ])
        [self.delegate appClient:self withMessage:message andBodyMessage:strOfJSONData];
}

#pragma mark - Private

- (void)drainMessageQueueIfReady {
    if ( !_peerConnection || !_hasReceivedSdp || _ICECandidateGatheringState != RTCICEGatheringComplete) {
        return;
    }
    for (ARDSignalingMessage *message in self.messageQueue) {
        [self processSignalingMessage:message];
    }
    [self.messageQueue removeAllObjects];
}

- (void)sendOffer
{
    [_peerConnection createOfferWithDelegate:self constraints:[self defaultOfferConstraints]];
}

-(void)sendAllGatheredLocalIceCandidates
{
    if ( _peerConnection.localDescription && _ICECandidateGatheringState == RTCICEGatheringComplete)
    {
        //        __weak ARDAppClient* weakSelf = self;
        //        dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        for ( NSArray* itemMessage in localIceCndidates ) {
            [self.delegate appClient:self withMessage:itemMessage[0] andBodyMessage:itemMessage[1] ];
        }
        //        });
    }
}

- (void)processSignalingMessage:(ARDSignalingMessage *)message {
    NSParameterAssert(_peerConnection ||
                      message.type == kARDSignalingMessageTypeBye);
    switch (message.type) {
        case kARDSignalingMessageTypeOffer:
        case kARDSignalingMessageTypeAnswer:
        {
            if ( !_peerConnection.remoteDescription ) {
                ARDSessionDescriptionMessage *sdpMessage = (ARDSessionDescriptionMessage *)message;
                RTCSessionDescription *description = sdpMessage.sessionDescription;
                
                [_peerConnection setRemoteDescriptionWithDelegate:self sessionDescription:description];
            }
            
            break;
        }
        case kARDSignalingMessageTypeCandidate: {
            ARDICECandidateMessage *candidateMessage = (ARDICECandidateMessage *) message;
            RTCICECandidate *candidate = candidateMessage.candidate;
            [_peerConnection addICECandidate:candidate];
            break;
        }
        case kARDSignalingMessageTypeBye:
            // Other client disconnected.
            // TODO(tkchin): support waiting in room for next client. For now just
            // disconnect.
            [self disconnect];
            break;
    }
}

//- (void)sendSignalingMessage:(ARDSignalingMessage *)message {
//    if (_isInitiator) {
//        [self sendSignalingMessageToRoomServer:message completionHandler:nil];
//    } else {
//        [self sendSignalingMessageToCollider:message];
//    }
//}


- (RTCVideoTrack *)createLocalVideoTrack:(AVCaptureDevicePosition)mediaType {
    // The iOS simulator doesn't provide any sort of camera capture
    // support or emulation (http://goo.gl/rHAnC1) so don't bother
    // trying to open a local stream.
    // TODO(tkchin): local video capture for OSX. See
    // https://code.google.com/p/webrtc/issues/detail?id=3417.
    
    RTCVideoTrack *localVideoTrack = nil;
#if !TARGET_IPHONE_SIMULATOR && TARGET_OS_IPHONE
    
    NSString *cameraID = nil;
    for (AVCaptureDevice *captureDevice in
         [AVCaptureDevice devicesWithMediaType:AVMediaTypeVideo]) {
        if (captureDevice.position == mediaType) {
            cameraID = [captureDevice localizedName];
            break;
        }
    }
    NSAssert(cameraID, @"Unable to get the front camera id");
    
    RTCVideoCapturer *capturer = [RTCVideoCapturer capturerWithDeviceName:cameraID];
    RTCMediaConstraints *mediaConstraints = [self defaultMediaStreamConstraints];
    RTCVideoSource *videoSource = [_factory videoSourceWithCapturer:capturer constraints:mediaConstraints];
    localVideoTrack = [_factory videoTrackWithID:@"ARDAMSv0" source:videoSource];
#endif
    return localVideoTrack;
}

- (RTCMediaStream *)createLocalMediaStream {
    RTCMediaStream* localStream = [_factory mediaStreamWithLabel:@"ARDAMS"];
    
    RTCVideoTrack *localVideoTrack = [self createLocalVideoTrack:cameraPosition];
    if (localVideoTrack) {
        [localStream addVideoTrack:localVideoTrack];
        [_delegate appClient:self didReceiveLocalVideoTrack:localVideoTrack];
    }
    
    [localStream addAudioTrack:[_factory audioTrackWithID:@"ARDAMSa0"]];
    if (_isSpeakerEnabled) [self enableSpeaker];
    return localStream;
}

//- (void)requestTURNServersWithURL:(NSURL *)requestURL
//                completionHandler:(void (^)(NSArray *turnServers))completionHandler {
//    NSParameterAssert([requestURL absoluteString].length);
//    NSMutableURLRequest *request =
//    [NSMutableURLRequest requestWithURL:requestURL];
//    // We need to set origin because TURN provider whitelists requests based on
//    // origin.
//    [request addValue:@"Mozilla/5.0" forHTTPHeaderField:@"user-agent"];
//    [request addValue:self.serverHostUrl forHTTPHeaderField:@"origin"];
//    [NSURLConnection sendAsyncRequest:request
//                    completionHandler:^(NSURLResponse *response,
//                                        NSData *data,
//                                        NSError *error) {
//                        NSArray *turnServers = [NSArray array];
//                        if (error) {
//                            NSLog(@"Unable to get TURN server.");
//                            completionHandler(turnServers);
//                            return;
//                        }
//                        NSDictionary *dict = [NSDictionary dictionaryWithJSONData:data];
//                        turnServers = [RTCICEServer serversFromCEODJSONDictionary:dict];
//                        completionHandler(turnServers);
//                    }];
//}

-(void)emergeError:(NSError *)error
{
    [self disconnect];
    
    [_delegate appClient:self didError:error];
}

#pragma mark - Defaults

- (RTCMediaConstraints *)defaultMediaStreamConstraints {
    RTCMediaConstraints* constraints =
    [[RTCMediaConstraints alloc]
     initWithMandatoryConstraints:nil
     optionalConstraints:nil];
    return constraints;
}

- (RTCMediaConstraints *)defaultAnswerConstraints {
    return [self defaultOfferConstraints];
}

- (RTCMediaConstraints *)defaultOfferConstraints {
    NSArray *mandatoryConstraints = @[
                                      [[RTCPair alloc] initWithKey:@"OfferToReceiveAudio" value:@"true"],
                                      [[RTCPair alloc] initWithKey:@"OfferToReceiveVideo" value:@"true"]
                                      ];
    RTCMediaConstraints* constraints =
    [[RTCMediaConstraints alloc]
     initWithMandatoryConstraints:mandatoryConstraints
     optionalConstraints:nil];
    return constraints;
}

- (RTCMediaConstraints *)defaultPeerConnectionConstraints {
    NSArray *optionalConstraints = @[
                                     [[RTCPair alloc] initWithKey:@"DtlsSrtpKeyAgreement" value:@"true"]
                                     ];
    RTCMediaConstraints* constraints =
    [[RTCMediaConstraints alloc]
     initWithMandatoryConstraints:nil
     optionalConstraints:optionalConstraints];
    return constraints;
}



#pragma mark - Audio mute/unmute
- (void)muteAudioIn {
    NSLog(@"audio muted");
    RTCMediaStream *localStream = _peerConnection.localStreams[0];
    self.defaultAudioTrack = localStream.audioTracks[0];
    [localStream removeAudioTrack:localStream.audioTracks[0]];
    [_peerConnection removeStream:localStream];
    [_peerConnection addStream:localStream];
}
- (void)unmuteAudioIn {
    NSLog(@"audio unmuted");
    RTCMediaStream* localStream = _peerConnection.localStreams[0];
    [localStream addAudioTrack:self.defaultAudioTrack];
    [_peerConnection removeStream:localStream];
    [_peerConnection addStream:localStream];
    if (_isSpeakerEnabled) [self enableSpeaker];
}

#pragma mark - Video mute/unmute
- (void)muteVideoIn {
    NSLog(@"video muted");
    RTCMediaStream *localStream = _peerConnection.localStreams[0];
    self.defaultVideoTrack = localStream.videoTracks[0];
    [localStream removeVideoTrack:localStream.videoTracks[0]];
    [_peerConnection removeStream:localStream];
    [_peerConnection addStream:localStream];
}
- (void)unmuteVideoIn {
    NSLog(@"video unmuted");
    RTCMediaStream* localStream = _peerConnection.localStreams[0];
    [localStream addVideoTrack:self.defaultVideoTrack];
    [_peerConnection removeStream:localStream];
    [_peerConnection addStream:localStream];
}

#pragma mark - swap camera

- (void)swapCameraToFront{
    [self swapCamera:AVCaptureDevicePositionFront];
}

- (void)swapCameraToBack {
    [self swapCamera:AVCaptureDevicePositionBack];
}

 - (void)swapCamera:(AVCaptureDevicePosition)camera {
     cameraPosition = camera;
     [self cleanUpAllMediaStreams];
 }

#pragma mark - enable/disable speaker

- (void)enableSpeaker {
    [[AVAudioSession sharedInstance] overrideOutputAudioPort:AVAudioSessionPortOverrideSpeaker error:nil];
    _isSpeakerEnabled = YES;
}

- (void)disableSpeaker {
    [[AVAudioSession sharedInstance] overrideOutputAudioPort:AVAudioSessionPortOverrideNone error:nil];
    _isSpeakerEnabled = NO;
}

@end
