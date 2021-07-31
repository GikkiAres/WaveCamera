	//
	//  ViewController.m
	//  WaveCamera
	//
	//  Created by Gikki Ares on 2021/6/14.
	//

#import "ViewController.h"
#import <AVFoundation/AVFoundation.h>
#import <OpenGLES/ES2/gl.h>
#import <OpenGLES/ES2/glext.h>




#define STRINGIZE(x) #x
#define SHADER_STRING(text) @ STRINGIZE(text)

static NSString * const kVertexShaderString = SHADER_STRING(
															attribute vec4 position;
															attribute vec2 textCoordinate;
															uniform mat4 rotateMatrix;
															varying highp vec2 textureCoordinate;
															void main()
{
	textureCoordinate = textCoordinate;
	vec4 vPos = position;
	vPos = vPos * rotateMatrix;
	gl_Position = vPos;
}
															);

static NSString *const kFragmentShaderString_wave = SHADER_STRING
(
 precision highp float;
 varying highp vec2 textureCoordinate;
 uniform sampler2D inputImageTexture;
 uniform float time;
 
#define TIME (time * 1.0 )
 
 void main() {
	vec2 uv = textureCoordinate;
	uv = uv * 0.8 + 0.1;
	uv += cos(TIME*vec2(6.0, 7.0) + uv*10.0)*0.02;
	gl_FragColor = texture2D(inputImageTexture, uv);
}
 );



static NSString *const kFragmentShaderString_passThrough = SHADER_STRING
(
 precision highp float;
 varying highp vec2 textureCoordinate;
 uniform sampler2D inputImageTexture;
 void main() {
	gl_FragColor = texture2D(inputImageTexture, textureCoordinate);
}
 );




@interface ViewController ()<
AVCaptureVideoDataOutputSampleBufferDelegate
>
{
	AVCaptureSession * mavCaptureSession;
	
	CAEAGLLayer * mcaEaglLayer;
	EAGLContext * meaglContext;
	
	
		//wave图像相关
	GLuint mi_gpuProgram_wave,mi_position_wave,mi_textCoor_wave,mi_textureUniform_wave,mi_rotate_wave,mi_time_wave;
	GLuint mi_framebuffer_wave,mi_texture_wave;
	CVOpenGLESTextureRef mcvOpenGlesTextureRef_wave;
	CVPixelBufferRef mcvPixelBufferRef_wave;
	
		//显示相关
	GLuint mi_gpuProgram_display,mi_position_display,mi_textCoor_display,mi_texture_display,mi_rotate_display;
	GLuint mi_renderbuffer_display,mi_framebuffer_display;
	
	CVOpenGLESTextureCacheRef mcvOpenGlesTextureCacheRef;
	CVOpenGLESTextureRef mcvOpenGlesTextrueRef_upload;
}



@end




@implementation ViewController

- (void)viewDidLoad {
	[super viewDidLoad];
	
	
		//CameraCapture
	[self setupCaptureSession];
	[self setupCaptureDeviceInput];
	[self setupOutput];
	
	
		//OpenGles init
	[self setupContext];
	[self setupEaglLayer];
	
	
	
	[self setupWaveProgram];
		//	[self destoryRenderAndFrameBuffer];
	
	[self setupDisplayProgram];
	[self setupDisplayRenderBuffer];
	[self setupDisplayFrameBuffer];
	
	
	
}



/**
 *  c语言编译流程：预编译、编译、汇编、链接
 *  glsl的编译过程主要有glCompileShader、glAttachShader、glLinkProgram三步；
 *  @param vert 顶点着色器
 *  @param frag 片元着色器
 *
 *  @return 编译成功的shaders
 */
- (GLuint)loadShaders:(NSString *)vert frag:(NSString *)frag {
	GLuint verShader, fragShader;
	GLint program = glCreateProgram();
	
		//编译
	[self compileShader:&verShader type:GL_VERTEX_SHADER file:vert];
	[self compileShader:&fragShader type:GL_FRAGMENT_SHADER file:frag];
	
	glAttachShader(program, verShader);
	glAttachShader(program, fragShader);
	
	
		//释放不需要的shader
	glDeleteShader(verShader);
	glDeleteShader(fragShader);
	
	return program;
}

- (void)compileShader:(GLuint *)shader type:(GLenum)type file:(NSString *)content {
		//读取字符串
	const GLchar* source = (GLchar *)[content UTF8String];
	
	*shader = glCreateShader(type);
	glShaderSource(*shader, 1, &source, NULL);
	glCompileShader(*shader);
	
		//如果编译失败输出原因
	GLint status;
	glGetShaderiv(*shader, GL_COMPILE_STATUS, &status);
	
	if (status != GL_TRUE) {
		GLint logLength;
		glGetShaderiv(*shader, GL_INFO_LOG_LENGTH, &logLength);
		if (logLength > 0) {
			GLchar *log = (GLchar *)malloc(logLength);
			glGetShaderInfoLog(*shader, logLength, &logLength, log);
			if (type == GL_VERTEX_SHADER)
			{
				NSString * vertexShaderLog = [NSString stringWithFormat:@"%s", log];
				NSLog(@"%@",vertexShaderLog);
			}
			else
			{
				NSString * fragmentShaderLog = [NSString stringWithFormat:@"%s", log];
				NSLog(@"%@",fragmentShaderLog);
			}
			
			free(log);
		}
	}
}

- (void)linkGpuProgram:(GLuint)gpuProgram {
		//链接
	glLinkProgram(gpuProgram);
	GLint linkSuccess;
	
	glGetProgramiv(gpuProgram, GL_LINK_STATUS, &linkSuccess);
	
	if (linkSuccess == GL_FALSE) { //连接错误
		
		GLchar messages[256];
		
		glGetProgramInfoLog(gpuProgram, sizeof(messages), 0, &messages[0]);
		
		NSString *messageString = [NSString stringWithUTF8String:messages];
		
		NSLog(@"error%@", messageString);
		
		return ;
		
	}else {
		
		NSLog(@"link ok");
	}
}


- (void)setupWaveProgram {
		//加载shader
	mi_gpuProgram_wave = [self loadShaders:kVertexShaderString frag:kFragmentShaderString_wave];
	[self linkGpuProgram:mi_gpuProgram_wave];
	
	glUseProgram(mi_gpuProgram_wave);
		//获取shader里面的变量，这里记得要在glLinkProgram后面，后面，后面！
		//顶点坐标
	mi_position_wave = glGetAttribLocation(mi_gpuProgram_wave, "position");
		//纹理坐标
	mi_textCoor_wave = glGetAttribLocation(mi_gpuProgram_wave, "textCoordinate");
		//纹理
	mi_textureUniform_wave = glGetUniformLocation(mi_gpuProgram_wave, "inputImageTexture");
		//旋转矩阵
	mi_rotate_wave = glGetUniformLocation(mi_gpuProgram_wave, "rotateMatrix");
		//
	mi_time_wave = glGetUniformLocation(mi_gpuProgram_wave, "time");
	
		
	//前三个是顶点坐标， 后面两个是纹理坐标
	GLfloat attrArr[] =
	{
		
		-1.0f, -1.0f, 0.f, //左下
		0.0f, 1.0f,//左下
		
		-1.0f, 1.0f, 0.f, //左上
		0.0f, 0.0f,//左上
		
		
		1.0f, -1.0f, 0.f, //右下
		1.0f, 1.0f,//右下
		
		
		
		1.0f, 1.0f, 0.f, //右上
		1.0f, 0.0f,
		
	};
	
	GLuint vertexBuffer;
	
	glGenBuffers(1, &vertexBuffer);
		// 绑定vertexBuffer到GL_ARRAY_BUFFER目标
	glBindBuffer(GL_ARRAY_BUFFER, vertexBuffer);
		// 设置缓冲数据
	glBufferData(GL_ARRAY_BUFFER, sizeof(attrArr), attrArr, GL_DYNAMIC_DRAW);
	
	

		//为变量赋值
	glVertexAttribPointer(mi_position_wave, 3, GL_FLOAT, GL_FALSE, sizeof(GLfloat) * 5, NULL);
	
	glVertexAttribPointer(mi_textCoor_wave, 2, GL_FLOAT, GL_FALSE, sizeof(GLfloat) * 5, (float *)NULL + 3);
	
	glEnableVertexAttribArray(mi_position_wave);
	
	glEnableVertexAttribArray(mi_textCoor_wave);
	
	GLfloat zRotation[16] = {
		1.0,0,0,0,
		0,1.0,0,0,
		0,0,1.0,0,
		0,0,0,1.0
	};
	
		//设置旋转矩阵
	glUniformMatrix4fv(mi_rotate_wave, 1, GL_FALSE, zRotation);
}

- (void)setupDisplayProgram {
		//加载shader
	mi_gpuProgram_display = [self loadShaders:kVertexShaderString frag:kFragmentShaderString_passThrough];
	[self linkGpuProgram:mi_gpuProgram_display];
	
	
	glUseProgram(mi_gpuProgram_display);
		//获取shader里面的变量，这里记得要在glLinkProgram后面，后面，后面！
		//顶点坐标
	mi_position_display = glGetAttribLocation(mi_gpuProgram_display, "position");
		//纹理坐标,从0开始的正整数
	mi_textCoor_display = glGetAttribLocation(mi_gpuProgram_display, "textCoordinate");
		//纹理
	mi_texture_display = glGetUniformLocation(mi_gpuProgram_display, "inputImageTexture");
	mi_rotate_display = glGetUniformLocation(mi_gpuProgram_display, "rotateMatrix");
	
	
		//前三个是顶点坐标， 后面两个是纹理坐标
	GLfloat attrArr[] =
	{
		
		-1.0f, -1.0f, 0.f, //左下
		0.0f, 1.0f,//左下     0
		
		-1.0f, 1.0f, 0.f, //左上
		0.0f, 0.0f,//左上    1
		
		
		1.0f, -1.0f, 0.f, //右下
		1.0f, 1.0f,//右下   2
		
		
		
		1.0f, 1.0f, 0.f, //右上  3
		1.0f, 0.0f,
		
	};
	
	GLuint vertexBuffer;
	glGenBuffers(1, &vertexBuffer);
		// 绑定vertexBuffer到GL_ARRAY_BUFFER目标
	glBindBuffer(GL_ARRAY_BUFFER, vertexBuffer);
		// 设置缓冲数据
	glBufferData(GL_ARRAY_BUFFER, sizeof(attrArr), attrArr, GL_DYNAMIC_DRAW);
	
	
	
		//为变量赋值
	glVertexAttribPointer(mi_position_display, 3, GL_FLOAT, GL_FALSE, sizeof(GLfloat) * 5, NULL);
	glVertexAttribPointer(mi_textCoor_display, 2, GL_FLOAT, GL_FALSE, sizeof(GLfloat) * 5, (float *)NULL + 3);
	
	glEnableVertexAttribArray(mi_position_display);
	glEnableVertexAttribArray(mi_textCoor_display);
	
	GLfloat zRotation[16] = {
		1.0,0,0,0,
		0,-1.0,0,0,
		0,0,1.0,0,
		0,0,0,1.0
	};
	
		//设置旋转矩阵,为当前的program指定,所以必须启用当前的program
	glUniformMatrix4fv(mi_rotate_display, 1, GL_FALSE, zRotation);
}

//- (void)setupWaveFrameBuffer:(GLuint)texture {
//	glGenFramebuffers(1, &mi_framebuffer_wave);
//	__unused GLuint framebufferCreationStatus = glCheckFramebufferStatus(GL_FRAMEBUFFER);
//	if(framebufferCreationStatus == GL_FRAMEBUFFER_COMPLETE) {
//		NSLog(@"Create wave framebuffer,success!");
//	}
//	else {
//		NSLog(@"Create wave framebuffer,fail!");
//	}
//}


- (void)setupDisplayFrameBuffer {
	glGenFramebuffers(1, &mi_framebuffer_display);
		// 设置为当前 framebuffer
	glBindFramebuffer(GL_FRAMEBUFFER, mi_framebuffer_display);
		// 将 _colorRenderBuffer 装配到 GL_COLOR_ATTACHMENT0 这个装配点上
	glFramebufferRenderbuffer(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0,
							  GL_RENDERBUFFER, mi_renderbuffer_display);
	__unused GLuint framebufferCreationStatus = glCheckFramebufferStatus(GL_FRAMEBUFFER);
	if(framebufferCreationStatus == GL_FRAMEBUFFER_COMPLETE) {
		NSLog(@"Create display framebuffer,success!");
	}
	else {
		NSLog(@"Create display framebuffer,fail!");
	}
	
	
	
}

	//- (void)destoryRenderAndFrameBuffer {
	//	if(mi_framebuffer) {
	//		glDeleteFramebuffers(1, &mi_framebuffer);
	//		mi_framebuffer = 0;
	//	}
	//	if(mi_renderbuffer) {
	//		glDeleteRenderbuffers(1, &mi_renderbuffer);
	//		mi_renderbuffer = 0;
	//	}
	//}

- (void)setupDisplayRenderBuffer {
	glGenRenderbuffers(1, &mi_renderbuffer_display);
	glBindRenderbuffer(GL_RENDERBUFFER, mi_renderbuffer_display);
		// 为 颜色缓冲区 分配存储空间
	[meaglContext renderbufferStorage:GL_RENDERBUFFER fromDrawable:mcaEaglLayer];
	GLint backingWidth, backingHeight;
	glGetRenderbufferParameteriv(GL_RENDERBUFFER, GL_RENDERBUFFER_WIDTH, &backingWidth);
	glGetRenderbufferParameteriv(GL_RENDERBUFFER, GL_RENDERBUFFER_HEIGHT, &backingHeight);
	NSLog(@"Display Render buffer width is:%d,height is:%d",backingWidth,backingHeight);
}

- (void)setupContext {
	EAGLRenderingAPI api = kEAGLRenderingAPIOpenGLES2;
	meaglContext = [[EAGLContext alloc] initWithAPI:api];
	if (!meaglContext) {
		NSLog(@"Failed to initialize OpenGLES 3.0 context");
		exit(1);
	}
	
		// 设置为当前上下文
	if (![EAGLContext setCurrentContext:meaglContext]) {
		NSLog(@"Failed to set current OpenGL context");
		exit(1);
	}
	
	CVReturn err = CVOpenGLESTextureCacheCreate(kCFAllocatorDefault, NULL, meaglContext, NULL, &mcvOpenGlesTextureCacheRef);
	if (err != kCVReturnSuccess) {
		NSLog(@"error");
	}
	NSLog(@"Setup context,successed.");
}


- (void)setupEaglLayer {
	mcaEaglLayer = [CAEAGLLayer layer];
	[self.view.layer addSublayer:mcaEaglLayer];
		//	mcaEaglLayer.backgroundColor = [UIColor blackColor].CGColor;
	mcaEaglLayer.bounds = [UIScreen mainScreen].bounds;
	mcaEaglLayer.position = self.view.center;
		//设置放大倍数
	[self.view setContentScaleFactor:[[UIScreen mainScreen] scale]];
	
		// CALayer 默认是透明的，必须将它设为不透明才能让其可见
	mcaEaglLayer.opaque = YES;
	
		// 设置描绘属性，在这里设置不维持渲染内容以及颜色格式为 RGBA8
	mcaEaglLayer.drawableProperties = @{
		kEAGLDrawablePropertyRetainedBacking:@(NO),
		kEAGLDrawablePropertyColorFormat:kEAGLColorFormatRGBA8
	};
}


- (void)setupCaptureSession {
	mavCaptureSession = [[AVCaptureSession alloc]init];
		//AVCaptureSessionPreset1920x1080
		//AVCaptureSessionPreset1280x720
	mavCaptureSession.sessionPreset = AVCaptureSessionPreset1920x1080;
}

- (void)setupCaptureDeviceInput{
	AVCaptureDeviceDiscoverySession *avCaptureDeviceDiscoverySession = [AVCaptureDeviceDiscoverySession  discoverySessionWithDeviceTypes:@[AVCaptureDeviceTypeBuiltInWideAngleCamera] mediaType:AVMediaTypeVideo position:AVCaptureDevicePositionBack];
	AVCaptureDevice * avCaptureDevice = avCaptureDeviceDiscoverySession.devices.firstObject;
	AVCaptureDeviceInput * avCaptureDeviceInput = [AVCaptureDeviceInput deviceInputWithDevice:avCaptureDevice error:nil];
	if([mavCaptureSession canAddInput:avCaptureDeviceInput]) {
		[mavCaptureSession addInput:avCaptureDeviceInput];
	}
	
		//如果当前设备支持自动对焦
	if(avCaptureDevice.autoFocusRangeRestrictionSupported) {
		if([avCaptureDevice lockForConfiguration:nil]) {
			avCaptureDevice.autoFocusRangeRestriction = AVCaptureAutoFocusRangeRestrictionNear;
		}
		[avCaptureDevice unlockForConfiguration];
	}
	else {
		
	}
	
}

- (void)setupOutput {
	AVCaptureVideoDataOutput * avCaptureOutput = [[AVCaptureVideoDataOutput alloc] init];
	avCaptureOutput.videoSettings = @{(id)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_32BGRA)};
	[avCaptureOutput setSampleBufferDelegate:self queue:dispatch_get_main_queue()];
	if ([mavCaptureSession canAddOutput:avCaptureOutput]) {
		[mavCaptureSession addOutput:avCaptureOutput];
	}
	
	AVCaptureConnection * avCaptureConnection = avCaptureOutput.connections.firstObject;
	if(avCaptureConnection.supportsVideoOrientation) {
		[avCaptureConnection setVideoOrientation:AVCaptureVideoOrientationPortrait];
	}
	if(avCaptureConnection.supportsVideoMirroring) {
		[avCaptureConnection setAutomaticallyAdjustsVideoMirroring:NO];
		[avCaptureConnection setVideoMirrored:NO];
	}
}



#pragma mark Delegate
-(void)captureOutput:(AVCaptureOutput *)output didOutputSampleBuffer:(CMSampleBufferRef)sampleBuffer fromConnection:(AVCaptureConnection *)connection {
	
	CFAbsoluteTime startTime = CFAbsoluteTimeGetCurrent();
	CVImageBufferRef pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer);
	int height	= (int) CVPixelBufferGetHeight(pixelBuffer);
	int width = (int) CVPixelBufferGetWidth(pixelBuffer);
	
	int texture = [self uploadSamplebufferToGpu:sampleBuffer];
	CMTime cmTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer);
	texture = [self waveFilterTextue:texture cmTime:cmTime width:width height:height];
	NSLog(@"Display texture is %d.",texture);
	[self displayTexture:texture];
	CFAbsoluteTime finishTime = CFAbsoluteTimeGetCurrent();
	CFAbsoluteTime duration = finishTime - startTime;
	NSLog(@"Process sample buffer,cost %.2f ms.",duration);
}

- (void)displayTexture:(GLuint)texture {
		//使用display程序显示
	glUseProgram(mi_gpuProgram_display);
	
	glActiveTexture(GL_TEXTURE0);
	glBindTexture(GL_TEXTURE_2D, texture);
	
		//切换到display framebufer
	glBindFramebuffer(GL_FRAMEBUFFER,mi_framebuffer_display);
	glBindRenderbuffer(GL_RENDERBUFFER, mi_renderbuffer_display);
		//这里是设置layer的大小,还是图片的???//要显示的layer的大小
		//获取视图放大倍数，可以把scale设置为1试试
	
		//设置视口大小
	int scale = [[UIScreen mainScreen] scale];
	glViewport(0, 0, self.view.frame.size.width * scale, self.view.frame.size.height * scale);
	
		//设置uniform
	glUniform1i(mi_texture_display, 0);
	
	glClearColor(1.0, 0.0, 0.0, 1.0);
	glClear(GL_COLOR_BUFFER_BIT);
	
	glDrawArrays(GL_TRIANGLE_STRIP, 0, 4);
	[meaglContext presentRenderbuffer:GL_RENDERBUFFER];
}

- (int)waveFilterTextue:(GLuint)texture cmTime:(CMTime)cmTime width:(int)width height:(int)height{

		//使用waveProgram上传图像
	glUseProgram(mi_gpuProgram_wave);
	
	if(!mi_framebuffer_wave) {
		CFDictionaryRef empty; // empty value for attr value.
		CFMutableDictionaryRef attrs;
		empty = CFDictionaryCreate(kCFAllocatorDefault, NULL, NULL, 0, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks); // our empty IOSurface properties dictionary
		attrs = CFDictionaryCreateMutable(kCFAllocatorDefault, 1, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
		CFDictionarySetValue(attrs, kCVPixelBufferIOSurfacePropertiesKey, empty);
			//创建能共享的CVPixelBuffer
		CVReturn err = CVPixelBufferCreate(kCFAllocatorDefault, (int)width, (int)height, kCVPixelFormatType_32BGRA, attrs, &mcvPixelBufferRef_wave);
		if (err){
			NSLog(@"FBO size: %d, %d", width, height);
			NSAssert(NO, @"Error at CVPixelBufferCreate %d", err);
		}
		
			//根据图片数据创建纹理缓存
		err = CVOpenGLESTextureCacheCreateTextureFromImage (kCFAllocatorDefault, mcvOpenGlesTextureCacheRef, mcvPixelBufferRef_wave,
															NULL, // texture attributes
															GL_TEXTURE_2D,
															GL_RGBA,// opengl format
															(int)width,
															(int)height,
															GL_BGRA, // native iOS format
															GL_UNSIGNED_BYTE,
															0,
															&mcvOpenGlesTextureRef_wave);
		if (err){
			NSAssert(NO, @"Error at CVOpenGLESTextureCacheCreateTextureFromImage %d", err);
		}
		
		CFRelease(attrs);
		CFRelease(empty);
		
		mi_texture_wave = CVOpenGLESTextureGetName(mcvOpenGlesTextureRef_wave);
		glBindTexture(CVOpenGLESTextureGetTarget(mcvOpenGlesTextureRef_wave), mi_texture_wave);
		
		glTexParameterf(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S,GL_CLAMP_TO_EDGE);
		glTexParameterf(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
	
		
		//framebuffer创建一次
	glGenFramebuffers(1, &mi_framebuffer_wave);
	glBindFramebuffer(GL_FRAMEBUFFER, mi_framebuffer_wave);
	
	glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D, mi_texture_wave, 0);
		//绑定当前上下文的framebuffer
	__unused GLuint framebufferCreationStatus = glCheckFramebufferStatus(GL_FRAMEBUFFER);
	NSAssert(framebufferCreationStatus == GL_FRAMEBUFFER_COMPLETE, @"Failure with wave framebuffer generation for filter");
	}
	
	//每次输出需要绑定framebuffer
	glBindFramebuffer(GL_FRAMEBUFFER, mi_framebuffer_wave);
	//!!! 这个函数可以影响framebuffer的图片的大小!!
	glViewport(0, 0, (int)width, (int)height);

	float time =CMTimeGetSeconds(cmTime);
	NSLog(@"Time is %.2f",time);
	glUniform1f(mi_time_wave, time);
	
	glActiveTexture(GL_TEXTURE0);
	glBindTexture(GL_TEXTURE_2D, texture);
	glUniform1i(mi_textureUniform_wave, 0);
	
	
	glClearColor(0.0, 0.0, 1.0, 1.0);
	glClear(GL_COLOR_BUFFER_BIT);
	glDrawArrays(GL_TRIANGLE_STRIP, 0, 4);
	return mi_texture_wave;
}

	//上传samplebuffer到gpu并处理返回rgba的纹理
- (int)uploadSamplebufferToGpu:(CMSampleBufferRef)samplebuffer {

	CVReturn err;
	CVImageBufferRef pixelBuffer = CMSampleBufferGetImageBuffer(samplebuffer);
	
	CMFormatDescriptionRef formatDescription = CMSampleBufferGetFormatDescription(samplebuffer);
	CMVideoDimensions dimensions = CMVideoFormatDescriptionGetDimensions(formatDescription);
	
	
	int heightImageInPixel	= (int) CVPixelBufferGetHeight(pixelBuffer);
	int widthImageInPixel = (int) CVPixelBufferGetWidth(pixelBuffer);
	
		//1080,1920
	NSLog(@"Width is %d,height is %d",dimensions.width,dimensions.height);
	NSLog(@"Width is %d,height is %d",widthImageInPixel,heightImageInPixel);
		//每一帧Samplebuffer都要上传.textureref,使用完毕后要删除.
	err = CVOpenGLESTextureCacheCreateTextureFromImage(kCFAllocatorDefault, mcvOpenGlesTextureCacheRef, pixelBuffer, NULL, GL_TEXTURE_2D, GL_RGBA, widthImageInPixel, heightImageInPixel, GL_BGRA, GL_UNSIGNED_BYTE, 0, &mcvOpenGlesTextrueRef_upload);
	if (err) {
		NSLog(@"error");
		return 0;
	}
		//纹理装配点
	GLenum target = CVOpenGLESTextureGetTarget(mcvOpenGlesTextrueRef_upload);
		//纹理id,是标识每个纹理的.
	GLuint name = CVOpenGLESTextureGetName(mcvOpenGlesTextrueRef_upload);
	NSLog(@"Texture id is %u",name);
	glActiveTexture(GL_TEXTURE0);
	glBindTexture(target, name);
	glTexParameterf(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
	glTexParameterf(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
	glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_NEAREST);
	glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_NEAREST);
	[self cleanupTextures];
	return name;
	
}


- (void)cleanupTextures {
	if (mcvOpenGlesTextrueRef_upload) {
		CFRelease(mcvOpenGlesTextrueRef_upload);
		mcvOpenGlesTextrueRef_upload = NULL;
	}
	CVOpenGLESTextureCacheFlush(mcvOpenGlesTextureCacheRef, 0);
}

- (void)captureOutput:(AVCaptureOutput *)output didDropSampleBuffer:(CMSampleBufferRef)sampleBuffer fromConnection:(AVCaptureConnection *)connection {
	NSLog(@"Drop");
}


#pragma mark Event

- (IBAction)onClickStart:(id)sender {
	[mavCaptureSession startRunning];
}

- (IBAction)onClickStop:(id)sender {
	[mavCaptureSession stopRunning];
}


@end
