//
//  QNMicrophoneRecorder.m
//  QNAudioRecorder
//
//  Created by tony.jing on 2021/12/8.
//

#import "QNMicrophoneRecorder.h"
#import <AudioToolbox/AudioToolbox.h>
#import <AVFoundation/AVFoundation.h>

#define kXDXAudioPCMFramesPerPacket 1
#define KXDXAudioBitsPerChannel 16
#define kQNMaxVolume 87.2984313

static inline void run_on_main_queue(void (^block)(void)) {
    dispatch_async(dispatch_get_main_queue(), block);
}

@interface QNMicrophoneRecorder()
@property (nonatomic, assign) AudioComponentInstance componentInstance;
@property (nonatomic, assign) AudioStreamBasicDescription asbd;
@property (nonatomic, strong) dispatch_source_t timer;
@property (nonatomic, assign) double volume;

@end

@implementation QNMicrophoneRecorder
{
    AudioBufferList *bufferList;
}

static QNMicrophoneRecorder *_sharedInstance;

#pragma mark - public
+(QNMicrophoneRecorder*) sharedInstance{
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        _sharedInstance = [[QNMicrophoneRecorder alloc] init];
    });
    return _sharedInstance;
}

// ========================================
#pragma mark - Initialization
// ========================================
- (id) init {
    if (self = [super init]) {
        [self setupASBD];
        [self setupAudioComponent];
        [self initializeAudioUnit];
    }
    return self;
}


/**
 * 开始录制
 *
 * @return 是否成功开始录制   YES：成功    NO：失败
 */
- (BOOL)startRecording{
    [self startTimer];
    OSStatus status = AudioOutputUnitStart(self.componentInstance);
    if (status != noErr) {
        return NO;
    }
    return YES;
}

/**
 * 停止录制
 *
 * @return 是否成功停止录制   YES：成功    NO：失败
 */
- (BOOL)stopRecording{
    OSStatus status = AudioOutputUnitStop(self.componentInstance);
    [self stopTimer];
    if (status != noErr) {
        return NO;
    }
    return YES;
}


#pragma -mark -Private

- (void)setupASBD {
    _asbd.mSampleRate = 44100;
    _asbd.mFormatID = kAudioFormatLinearPCM;
    _asbd.mFormatFlags = kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked;
    _asbd.mChannelsPerFrame = 1;
    _asbd.mFramesPerPacket = 1;
    _asbd.mBitsPerChannel = 16;
    _asbd.mBytesPerFrame = _asbd.mBitsPerChannel / 8 * _asbd.mChannelsPerFrame;
    _asbd.mBytesPerPacket = _asbd.mBytesPerFrame * _asbd.mFramesPerPacket;
}

- (void)setupAudioComponent {
    AudioComponentDescription acd;
    acd.componentType = kAudioUnitType_Output;
    acd.componentSubType = kAudioUnitSubType_VoiceProcessingIO;
    acd.componentManufacturer = kAudioUnitManufacturer_Apple;
    acd.componentFlags = 0;
    acd.componentFlagsMask = 0;

    AudioComponent component = AudioComponentFindNext(NULL, &acd);
    OSStatus status = AudioComponentInstanceNew(component, &_componentInstance);
    if (noErr != status) {
        NSLog(@"AudioComponentInstanceNew error, status: %d", status);
        return;
    }

    UInt32 flagOne = 1;
    AudioUnitSetProperty(self.componentInstance, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input, 1, &flagOne, sizeof(flagOne));

    AURenderCallbackStruct cb;
    cb.inputProcRefCon = (__bridge void *)(self);
    cb.inputProc = RecordCallback;
    AudioUnitSetProperty(self.componentInstance, kAudioOutputUnitProperty_SetInputCallback, kAudioUnitScope_Global, 1, &cb, sizeof(cb));
    
    flagOne = 0;
    status = AudioUnitSetProperty(self.componentInstance,kAudioUnitProperty_ShouldAllocateBuffer, kAudioUnitScope_Input, 1, &flagOne, sizeof(flagOne));
    if (noErr != status) {
        NSLog(@"AudioUnitSetProperty error, status: %d", status);
        return;
    }
}

- (void)initializeAudioUnit {

    AudioUnitSetProperty(self.componentInstance, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 1, &_asbd, sizeof(_asbd));
    OSStatus status = AudioUnitInitialize(self.componentInstance);
    if (noErr != status) {
        NSLog(@"AudioUnitInitialize error, status: %d", status);
        return;
    }

}

static OSStatus RecordCallback(void *inRefCon,
                               AudioUnitRenderActionFlags *ioActionFlags,
                               const AudioTimeStamp *inTimeStamp,
                               UInt32 inBusNumber,
                               UInt32 inNumberFrames,
                               AudioBufferList *ioData){
    
    QNMicrophoneRecorder *audioRecorder = (__bridge QNMicrophoneRecorder*)inRefCon;
    AudioBuffer buffer;
    buffer.mDataByteSize = inNumberFrames * 2;
    buffer.mData = malloc(buffer.mDataByteSize);
    buffer.mNumberChannels = 1;
    
    AudioBufferList bufferList;
    bufferList.mNumberBuffers = 1;
    bufferList.mBuffers[0] = buffer;

    OSStatus status = AudioUnitRender(audioRecorder->_componentInstance,
                                      ioActionFlags,
                                      inTimeStamp,
                                      inBusNumber,
                                      inNumberFrames,
                                      &bufferList);
    [audioRecorder volumeWithAudioBuffer:&buffer];
    free(buffer.mData);
    
    return status;
}

#pragma mark - Volume Util Methods
- (float)volumeWithAudioBuffer:(AudioBuffer *)audioBuffer {
    if (audioBuffer->mDataByteSize == 0) {
        return 0.0;
    }
    
    long long pcmAllLenght = 0;
    short bufferByte[audioBuffer->mDataByteSize/2];
    memcpy(bufferByte, audioBuffer->mData, audioBuffer->mDataByteSize);
    
    // 将 buffer 内容取出，进行平方和运算
    for (int i = 0; i < audioBuffer->mDataByteSize/2; i++) {
        pcmAllLenght += bufferByte[i] * bufferByte[i];
    }
    // 平方和除以数据总长度，得到音量大小。
    float mean = pcmAllLenght / (double)audioBuffer->mDataByteSize;
    self.volume = 0.0;
    if (mean != 0) {
        self.volume =10 * log10(mean);
    }
    self.volume = fabs(self.volume)/kQNMaxVolume;
    return self.volume;
}

#pragma mark - Timer
- (void)startTimer {
    self.timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, NULL);
    dispatch_source_set_timer(self.timer, DISPATCH_TIME_NOW, 0.1 * NSEC_PER_SEC, 0);
    __weak typeof(self) weakSelf = self;
    dispatch_source_set_event_handler(self.timer, ^{
        run_on_main_queue(^{
            if (weakSelf.delegate && [weakSelf.delegate respondsToSelector:@selector(audioRecorder:onVolumeChanged:)]) {
                [weakSelf.delegate audioRecorder:weakSelf onVolumeChanged:weakSelf.volume];
            }
        });
    });
    dispatch_resume(self.timer);
}

- (void)stopTimer {
    if (self.timer) {
        dispatch_cancel(self.timer);
        self.timer = nil;
    }
}

@end
