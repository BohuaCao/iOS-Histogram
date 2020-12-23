//
//  KdHistogramView.m
//  Narwal
//
//  Created by Kandao_user on 2020/12/11.
//

#import "KdHistogramView.h"
#import "UIBezierPath+NarwalUtils.h"
#import <CoreGraphics/CoreGraphics.h>
#import <CoreImage/CoreImage.h>
#import <Accelerate/Accelerate.h>

#define DEFAULT_WIDTH 126.0
#define DEFAULT_HEIGHT 64.0

/// when set, uses the ITU BT.709 colour constant; HSP is used otherwise.
#define	USE_ITU_LUMA	1

/// enum for channels
typedef NS_ENUM(NSUInteger, TSHistogramChannel) {
	kTSChannelRed		= 0,
	kTSChannelGreen		= 1,
	kTSChannelBlue		= 2,
    
	kTSChannelLuminance	= 3
};

/// background colour to use for buffers
static const CGFloat TSImageBufBGColour[] = {0, 0, 0, 0};

/// padding at the top of the curves
static const CGFloat TSCurveTopPadding = 2.f;

/// Alpha component for a channel curve fill
static const CGFloat TSCurveFillAlpha = 0.5f;
/// Alpha component for a channel curve stroke
static const CGFloat TSCurveStrokeAlpha = 0.75f;

/// Duration of the animation between histogram paths
static const CGFloat TSPathAnimationDuration = 0.33;

/// Histogram buckets per channel; fixed to 256 since we use 8-bit data.
static const NSUInteger TSHistogramBuckets = 256;

/// KVO context for the image key
static void *TSImageKVOCtx = &TSImageKVOCtx;
/// KVO context for the quality key
static void *TSQualityKVOCtx = &TSQualityKVOCtx;

@interface KdHistogramView ()

/// This is the image of which we calculate the histogram
@property (nonatomic) UIImage *image;

/// Quality of the histogram, between 1 and 4; Each step causes a size reduction of 1/2.
@property (nonatomic) NSUInteger quality;

/// border/curve container
@property (nonatomic) CALayer *border;
/// red channel curve
@property (nonatomic) CAShapeLayer *rLayer;
/// green channel curve
@property (nonatomic) CAShapeLayer *gLayer;
/// blue channel curve
@property (nonatomic) CAShapeLayer *bLayer;
/// luminance (calculated) curve
@property (nonatomic) CAShapeLayer *yLayer;

/// temporary histogram buffer; straight from vImage
@property (nonatomic) vImagePixelCount *histogram;
/// maximum value for the histomagram in any channel
@property (nonatomic) vImagePixelCount histogramMax;
/// when set, the histogram is considered valid
@property (nonatomic) BOOL isHistogramValid;

/// buffer to use for images
@property (nonatomic) vImage_Buffer *imgBuf;
/// whether the image buffer is valid
@property (nonatomic) BOOL isImgBufValid;

@property (nonatomic) dispatch_queue_t updateQueue;

- (void) setUpLayers;
- (void) setUpCurveLayer:(CAShapeLayer *) curve withChannel:(TSHistogramChannel) c;
- (void) resetCurveLayer:(CAShapeLayer *) layer withAnimation:(BOOL) animate;

- (void) allocateBuffers;
- (void) updateImageBuffer;

- (void) layOutSublayers;

- (void) updateDisplay;
- (void) calculateHistogram;
- (void) updateHistogramPathsWithAnimation:(BOOL) shouldAnimate;

- (void) produceScaledVersionForHistogram;

- (NSArray<NSValue *> *) pointsForChannel:(TSHistogramChannel) c;
- (UIBezierPath *) pathForCurvePts:(NSArray<NSValue *> *) points;

- (void) animatePathChange:(UIBezierPath *) path inLayer:(CAShapeLayer *) layer;

@end

@implementation KdHistogramView

- (instancetype) initWithCoder:(NSCoder *)coder {
	if(self = [super initWithCoder:coder]) {
		[self setUpLayers];
		[self allocateBuffers];
    
		self.quality = 4;
        self.backgroundColor = [UIColor colorWithRed:0.0 green:0.0 blue:0.0 alpha:0.4];
		
		// add KVO for properties that cause recomputation of the histogram
//		[self addObserver:self forKeyPath:@"image" options:0
//				  context:TSImageKVOCtx];
//		[self addObserver:self forKeyPath:@"quality" options:0
//				  context:TSQualityKVOCtx];
	}
	
	return self;
}

- (instancetype)initWithFrame:(CGRect)frame
{
    self = [super initWithFrame:frame];
    if (self) {
        [self setUpLayers];
        [self allocateBuffers];
        
        self.quality = 4;
        self.backgroundColor = [UIColor colorWithRed:0.0 green:0.0 blue:0.0 alpha:0.4];
        self.updateQueue = dispatch_queue_create("com.kandaovr.qoocam.histogram.updateQueue", DISPATCH_QUEUE_SERIAL);
		 
        //add close button
        UIButton *closeButton = [[UIButton alloc] initWithFrame:CGRectMake(self.width - 22.0, 2.0, 20.0, 20.0)];
        [closeButton setImage:[UIImage imageNamed:@"btn_close"] forState:UIControlStateNormal];
        [closeButton addTarget:self action:@selector(closeButtonClicked:) forControlEvents:UIControlEventTouchUpInside];
        [self addSubview:closeButton];
        
        // add KVO for properties that cause recomputation of the histogram
//        [self addObserver:self forKeyPath:@"image" options:0
//                  context:TSImageKVOCtx];
//        [self addObserver:self forKeyPath:@"quality" options:0
//                  context:TSQualityKVOCtx];
    }
    return self;
}

- (void)setFrame:(CGRect)frame {
    [super setFrame:frame];
    [self layOutSublayers];
}

- (CGRect)bounds {
    if ([NSThread currentThread].isMainThread) {
        return [super bounds];
    } else {
        __block CGRect bounds;
        dispatch_sync(dispatch_get_main_queue(), ^{
            bounds = self.bounds;
        });
        return bounds;
    }
}

#pragma mark - Public
+ (instancetype)showInView:(UIView *)view {
    KdHistogramView *histogramView = [[KdHistogramView alloc] initWithFrame:CGRectMake(80.0, view.bounds.size.height - 58.0 - DEFAULT_HEIGHT, DEFAULT_WIDTH, DEFAULT_HEIGHT)];
    [view addSubview:histogramView];
    return histogramView;
}

+ (void)hideForView:(UIView *)view {
    UIView *targetView = nil;
    for (UIView *subview in view.subviews) {
        if ([subview isKindOfClass:[KdHistogramView class]]) {
            targetView = subview;
            break;
        }
    }
    if (targetView) {
        targetView.hidden = true;
        [targetView removeFromSuperview];
    }
}

- (void)updateWithPixelBuffer:(CVPixelBufferRef)pixelBuffer {
    [self updateImage:[self imageFromCVPixelBuffer:pixelBuffer] andQuality:4.0];
}

- (void)updateImage:(UIImage *)image andQuality:(NSUInteger)quality {
    __weak typeof(self) weakSelf = self;
    
    // image changed; update buffer and histogram.
    if(self.image != image) {
        self.image = image;
        self.isHistogramValid = NO;
        
        // update the image buffer with new data, on a background queue
        if(self.image != nil) {
            dispatch_async(self.updateQueue, ^{
                // scale image, and update buffer
                [weakSelf produceScaledVersionForHistogram];
                [weakSelf updateImageBuffer];
                
                // now, update display
                [weakSelf updateDisplay];
                
                //redraw histogram
                dispatch_async(dispatch_get_main_queue(), ^{
                    [weakSelf layOutSublayers];
                });
            });
        } else {
            // update display to make paths nil
            [self updateDisplay];
        }
    }
    
    // the quality has changed; update the buffer.
    if(self.quality != quality) {
        self.quality = quality;
        self.isImgBufValid = NO;
        
        // update the image buffer and histogram, if an image is loaded
        if(self.image != nil) {
            dispatch_async(self.updateQueue, ^{
                // create a new image, update the buffer and display
                [weakSelf produceScaledVersionForHistogram];
                [weakSelf updateImageBuffer];
                
                [weakSelf updateDisplay];
                
                //redraw histogram
                dispatch_async(dispatch_get_main_queue(), ^{
                    [weakSelf layOutSublayers];
                });
            });
        } else {
            // invalidate image buffer and do nothing else.
            [self invalidateImageBuffer];
        }
    }
}

#pragma mark Drawing
/**
 * Draws the border, and fills the view with a semi-transparent grey.
 */
//- (void)drawRect:(CGRect)rect {
//	// clear dirty rect
//	[[UIColor clearColor] setFill];
//    UIRectFill(rect);
//
//	// fill the content
//	CGRect content = CGRectInset(self.bounds, 1, 1);
//    [[UIColor colorWithWhite:0.f alpha:0.25f] setFill];
//	UIRectFill(content);
//
//	// stroke the border
//	[[UIColor labelColor] setStroke];
//	UIBezierPath *p = [UIBezierPath bezierPath];
//
//	[p moveToPoint:CGPointMake(0, 0)];
//
//	[p addLineToPoint:CGPointMake(self.bounds.size.width, 0)];
//	[p moveToPoint:CGPointMake(self.bounds.size.width, 1)];
//
//	[p addLineToPoint:CGPointMake(self.bounds.size.width, self.bounds.size.height)];
//	[p moveToPoint:CGPointMake(self.bounds.size.width - 1, self.bounds.size.height)];
//
//	[p addLineToPoint:CGPointMake(0, self.bounds.size.height)];
//	[p moveToPoint:CGPointMake(0, self.bounds.size.height - 1)];
//
//	[p addLineToPoint:CGPointMake(0, 1)];
//
//	[p stroke];
//}

/**
 * Allow vibrancy.
 */
- (BOOL) allowsVibrancy {
	return YES;
}

#pragma mark Layers
/**
 * Sets up the view's layers.
 */
- (void) setUpLayers {
	// create the container for the histograms
	self.border = [CALayer layer];
	self.border.masksToBounds = YES;
	
	// set up the curve layers
	self.yLayer = [CAShapeLayer layer];
	self.rLayer = [CAShapeLayer layer];
	self.gLayer = [CAShapeLayer layer];
	self.bLayer = [CAShapeLayer layer];
	
	[self setUpCurveLayer:self.yLayer withChannel:kTSChannelLuminance];
	[self setUpCurveLayer:self.rLayer withChannel:kTSChannelRed];
	[self setUpCurveLayer:self.gLayer withChannel:kTSChannelGreen];
	[self setUpCurveLayer:self.bLayer withChannel:kTSChannelBlue];
	
	// add layers (stacked such that it's ordered B -> G -> R -> Y)
	[self.border addSublayer:self.yLayer];
	[self.border insertSublayer:self.rLayer above:self.yLayer];
	[self.border insertSublayer:self.gLayer above:self.rLayer];
	[self.border insertSublayer:self.bLayer above:self.gLayer];
	
	[self.layer addSublayer:self.border];
}

/**
 * Sets up a curve layer.
 */
- (void) setUpCurveLayer:(CAShapeLayer *) curve withChannel:(TSHistogramChannel) c {
	// calculate colours
	CGFloat r, g, b;
	
	if(c <= kTSChannelBlue) {
		r = (c == 0) ? 1.f : 0.f;
		g = (c == 1) ? 1.f : 0.f;
		b = (c == 2) ? 1.f : 0.f;
	} else {
		r = g = b = 1.f;
	}
	
	// set the fills
	curve.fillColor = [UIColor colorWithRed:r green:g blue:b alpha:TSCurveFillAlpha].CGColor;
	curve.strokeColor = [UIColor colorWithRed:r green:g blue:b alpha:TSCurveStrokeAlpha].CGColor;
	
	curve.lineJoin = kCALineJoinRound;
	
	curve.lineWidth = 1.f;
	curve.masksToBounds = YES;
}

/**
 * Resets a curve layer to show nothing. This generates a default path,
 * which consists of a single, 1pt line, just underneath the visible
 * viewport.
 */
- (void) resetCurveLayer:(CAShapeLayer *) layer withAnimation:(BOOL) animate {
	CGSize curveSz = CGRectInset(self.bounds, 0, 0).size;
	
	// create the path
	UIBezierPath *path = [UIBezierPath new];
	
	[path moveToPoint:CGPointMake(0, curveSz.height)];
	
	for(NSUInteger i = 0; i < TSHistogramBuckets; i++) {
		CGFloat x = (((CGFloat) i) / ((CGFloat) TSHistogramBuckets - 1) * curveSz.width) - 1.f;
		
		[path addLineToPoint:CGPointMake(x, curveSz.height)];
	}
	
	[path addLineToPoint:CGPointMake(0, curveSz.height)];
	
	// set it pls
	if(animate) {
		[self animatePathChange:path inLayer:layer];
	} else {
		layer.path = path.CGPath;
	}
}

#pragma mark Buffers
/**
 * Allocates buffers of raw histogram data.
 */
- (void) allocateBuffers {
	self.histogram = (vImagePixelCount *)calloc((TSHistogramBuckets * 4), sizeof(vImagePixelCount));
	
	self.imgBuf = (vImage_Buffer *)calloc(1, sizeof(vImage_Buffer));
}

/**
 * Updates the cached vImage buffer for the image.
 */
- (void) updateImageBuffer {
	NSAssert(self.image != nil, @"Image may not be nill for buffer allocation");
	
	// free the memory of the original buffer
	[self invalidateImageBuffer];
	
	// create a vImage buffer and load the image into it
	vImage_CGImageFormat format = {
		.version = 0,
		
		.bitsPerComponent = 8,
		.bitsPerPixel = 32,
		.bitmapInfo = (CGBitmapInfo) kCGImageAlphaNoneSkipLast,
		
		.renderingIntent = kCGRenderingIntentDefault,
		.colorSpace = nil,
		
		.decode = nil
	};
	
	vImageBuffer_InitWithCGImage(self.imgBuf, &format, TSImageBufBGColour, self.image.CGImage, kvImageNoFlags);
	
	// mark buffer as valid
	self.isImgBufValid = YES;
}

/**
 * Invalidates the image buffer.
 */
- (void) invalidateImageBuffer {
	// set buffer state to invalid
	self.isImgBufValid = NO;
	
	// free its memory
	if(self.imgBuf->data != nil) {
		free(self.imgBuf->data);
		self.imgBuf->data = nil;
	}
}

/**
 * Frees buffers that were previously manually allocated.
 */
- (void) dealloc {
	// free histogram buffer
	free(self.histogram);
	
	// free image buffer and its struct
	[self invalidateImageBuffer];
	free(self.imgBuf);
	
	// remove observer
	[[NSNotificationCenter defaultCenter] removeObserver:self];
}

/**
 * KVO handler
 */
- (void) observeValueForKeyPath:(NSString *) keyPath
					   ofObject:(id) object
						 change:(NSDictionary<NSString *,id> *) change
						context:(void *) context {
    __weak typeof(self) weakSelf = self;
	// image changed; update buffer and histogram.
	if(context == TSImageKVOCtx) {
		self.isHistogramValid = NO;
		
		// update the image buffer with new data, on a background queue
		if(self.image != nil) {
			dispatch_async(self.updateQueue, ^{
				// scale image, and update buffer
				[weakSelf produceScaledVersionForHistogram];
				[weakSelf updateImageBuffer];
				
				// now, update display
				[weakSelf updateDisplay];
			});
		} else {
			// update display to make paths nil
			[self updateDisplay];
		}
        
        //redraw histogram
        [self layOutSublayers];
	}
	// the quality has changed; update the buffer.
	else if(context == TSQualityKVOCtx) {
		self.isImgBufValid = NO;
		
		// update the image buffer and histogram, if an image is loaded
		if(self.image != nil) {
			dispatch_async(self.updateQueue, ^{
				// create a new image, update the buffer and display
				[weakSelf produceScaledVersionForHistogram];
				[weakSelf updateImageBuffer];
				
				[weakSelf updateDisplay];
			});
		} else {
			// invalidate image buffer and do nothing else.
			[self invalidateImageBuffer];
		}
	}
}

#pragma mark Layout
/**
 * Re-aligns layers and updates their contents scale, when the backing
 * store of the view changes.
 */
//- (void) viewDidChangeBackingProperties {
//	[super viewDidChangeBackingProperties];
//
//	self.layer.contentsScale = self.window.backingScaleFactor;
//
//	self.border.contentsScale = self.window.backingScaleFactor;
//
//	self.yLayer.contentsScale = self.window.backingScaleFactor;
//	self.rLayer.contentsScale = self.window.backingScaleFactor;
//	self.gLayer.contentsScale = self.window.backingScaleFactor;
//	self.bLayer.contentsScale = self.window.backingScaleFactor;
//}

/**
 * Lays out all of the sublayers to fit in the view.
 */
- (void) layOutSublayers {
	CGRect frame = self.bounds;
	
	// begin a transaction (disabling implicit animations)
	[CATransaction begin];
	[CATransaction setValue:(id)kCFBooleanTrue forKey:kCATransactionDisableActions];
	
	// lay out the border
	self.border.frame = frame;
	
	// lay out the curves' shape layers
	CGRect curvesFrame = CGRectInset(frame, 1, 1);
	
	self.yLayer.frame = curvesFrame;
	self.rLayer.frame = curvesFrame;
	self.gLayer.frame = curvesFrame;
	self.bLayer.frame = curvesFrame;
	
	// if no image is loaded, set up the placeholder frame
	if(self.image == nil) {
		[self resetCurveLayer:self.yLayer withAnimation:NO];
		[self resetCurveLayer:self.rLayer withAnimation:NO];
		[self resetCurveLayer:self.gLayer withAnimation:NO];
		[self resetCurveLayer:self.bLayer withAnimation:NO];
	}
	
	// commit transaction
	[CATransaction commit];
	
	// update the histogram paths
	if(self.image != nil) {
		[self updateHistogramPathsWithAnimation:NO];
	}
}

/**
 * Use a flipped coordinate system.
 */
- (BOOL) isFlipped {
	return YES;
}

/**
 * Forces the view's histogram to be redrawn.
 */
- (void) redrawHistogram {
	[self layOutSublayers];
}

#pragma mark Histogram Calculation
/**
 * Re-calculates the histogram for the image that was assigned to the
 * control.
 */
- (void) updateDisplay {
	// if the image became nil, hide the histograms
	if(self.image == nil) {
		dispatch_async(dispatch_get_main_queue(), ^{
			// set the paths to nil
			[self resetCurveLayer:self.yLayer withAnimation:YES];
			[self resetCurveLayer:self.rLayer withAnimation:YES];
			[self resetCurveLayer:self.gLayer withAnimation:YES];
			[self resetCurveLayer:self.bLayer withAnimation:YES];
		});
		
		return;
	}
	
	// re-calculate histogram; if image ≠ nil, this should be on bg thread
	[self calculateHistogram];
}

/**
 * Performs calculation of histogram data, scales it, then calculates an
 * interpolated bezier path for each component.
 *
 * @note This _must_ be called on a background thread. It is slow.
 */
- (void) calculateHistogram {
	NSUInteger i, c, y, x, o;
	
	/**
	 * Calculates luminance over the entire image. This works pixel by
	 * pixel, and stores luminance in the alpha component.
	 *
	 * The luminance formula used uses ITU BT.709 constants, or the HSP
	 * colour model's "perceived brightness" value, depending on the
	 * value of USE_ITU_LUMA.
	 */	
	CGFloat luma;
	
	uint8_t *ptrR = (uint8_t *)self.imgBuf->data;
	uint8_t *ptrG = ptrR + 1;
	uint8_t *ptrB = ptrR + 2;
	uint8_t *ptrA = ptrR + 3;
	
	size_t height = CGImageGetHeight(self.image.CGImage);
	size_t width = CGImageGetWidth(self.image.CGImage);
	
	for(y = 0; y < height; y++) {
		// calculate luminance for each pixel and shove it in the alpha
		for(x = 0; x < width; x++) {
			o = (x * 4);
			
			// read RGB, then apply luminance formula
			CGFloat r = ptrR[o], g = ptrG[o], b = ptrB[0];
			
#if USE_ITU_LUMA
			luma = (0.2126 * r) + (0.7152 * g) + (0.0722 * b);
#else
			luma = sqrt((0.299 * pow(r, 2)) + (0.587 * pow(g, 2)) + (0.114 * pow(b, 2)));
#endif
			
			// store it
			ptrA[o] = (uint8_t) luma;
		}
		
		// go to the next row
		ptrR += self.imgBuf->rowBytes;
		ptrG += self.imgBuf->rowBytes;
		ptrB += self.imgBuf->rowBytes;
		ptrA += self.imgBuf->rowBytes;
	}
	
	
	// calculate the histogram, from already loaded image data
	vImagePixelCount *histogramPtr[] = {
		self.histogram,
		self.histogram + (TSHistogramBuckets * 1),
		self.histogram + (TSHistogramBuckets * 2),
		self.histogram + (TSHistogramBuckets * 3),
	};
	
	vImageHistogramCalculation_ARGB8888(self.imgBuf, histogramPtr,
										kvImageNoFlags);
	
	// find the maximum value in the buffer, even for the luma component
	self.histogramMax = 0;
	
	for(i = 0; i < TSHistogramBuckets; i++) {
		for(c = 0; c < 4; c++) {
			// check if it's higher than the max value
			if(self.histogramMax < histogramPtr[c][i]) {
				self.histogramMax = histogramPtr[c][i];
			}
		}
	}
	
	// mark the histogram as valid again, then draw
	if(self.histogramMax > 0) {
		self.isHistogramValid = YES;
	}
	
	[self updateHistogramPathsWithAnimation:YES];
}

#pragma mark Histogram Display
/**
 * Takes the scaled histogram data and turns it into paths.
 */
- (void) updateHistogramPathsWithAnimation:(BOOL) shouldAnimate {
	// return if the histogram is not valid
	if(self.isHistogramValid == NO)
		return;
	
	// get points for each channel
	NSArray *yPoints = [self pointsForChannel:kTSChannelLuminance];
	NSArray *rPoints = [self pointsForChannel:kTSChannelRed];
	NSArray *gPoints = [self pointsForChannel:kTSChannelGreen];
	NSArray *bPoints = [self pointsForChannel:kTSChannelBlue];
	
	// make the paths
	UIBezierPath *lumaPath = [self pathForCurvePts:yPoints];
	UIBezierPath *redPath = [self pathForCurvePts:rPoints];
	UIBezierPath *greenPath = [self pathForCurvePts:gPoints];
	UIBezierPath *bluePath = [self pathForCurvePts:bPoints];
	
	// set the paths on the main thread, with animation
	dispatch_async(dispatch_get_main_queue(), ^{
		if(shouldAnimate) {
			[self animatePathChange:lumaPath inLayer:self.yLayer];
			[self animatePathChange:redPath inLayer:self.rLayer];
			[self animatePathChange:greenPath inLayer:self.gLayer];
			[self animatePathChange:bluePath inLayer:self.bLayer];
		} else {
			self.yLayer.path = lumaPath.CGPath;
			self.rLayer.path = redPath.CGPath;
			self.gLayer.path = greenPath.CGPath;
			self.bLayer.path = bluePath.CGPath;
		}
	});
}

/**
 * Creates an array of points, given a channel of the histogram.
 */
- (NSArray<NSValue *> *) pointsForChannel:(TSHistogramChannel) c {
	NSMutableArray<NSValue *> *points = [NSMutableArray new];
	
	// calculate size of the area curves occupy
	CGSize curveSz = CGRectInset(self.bounds, 0, 0).size;
	curveSz.height -= TSCurveTopPadding;
	
	// get the buffer for the histogram
	vImagePixelCount *buffer = self.histogram;
	buffer += (c * TSHistogramBuckets);
	
	// create points for each of the points
	for(NSUInteger i = 0; i < TSHistogramBuckets; i++) {
		// calculate X and Y positions
		CGFloat x = (((CGFloat) i) / ((CGFloat) TSHistogramBuckets - 1) * curveSz.width) - 1.f;
		
		CGFloat y = curveSz.height - (((CGFloat) buffer[i]) / ((CGFloat) self.histogramMax) * curveSz.height);
		NSLog(@"x: %.2f y: %.2f", x, y);
        
		// make point and store it
		[points addObject:[NSValue valueWithCGPoint:CGPointMake(x, y)]];
	}
	
	// done
	return [points copy];
}

/**
 * Makes a path for a curve, given a set of points.
 */
- (UIBezierPath *) pathForCurvePts:(NSArray<NSValue *> *) points {
	CGSize curveSz = CGRectInset(self.bounds, 0, 0).size;
	
	// start the main path
	UIBezierPath *path = [UIBezierPath new];
	[path moveToPoint:CGPointMake(0, curveSz.height)];
	
	// append the interpolated points
	UIBezierPath *curvePath = [UIBezierPath new];
	[curvePath interpolatePointsWithHermite:points];
	[path appendPath:curvePath];
	
	// close the path
	[path addLineToPoint:CGPointMake(curveSz.width, curveSz.height)];
	[path addLineToPoint:CGPointMake(0, curveSz.height)];
	
	// done
	return path;
}

/**
 * Animates the change of the path value on the given layer. Once the
 * animation has completed, it is removed, and the path value updated.
 */
- (void) animatePathChange:(UIBezierPath *) path inLayer:(CAShapeLayer *) layer {
	// is the path nil? if so, just set it.
	if(layer.path == nil) {
		layer.path = path.CGPath;
		return;
	}
	
	// remove any existing animations and start transaction
	[layer removeAllAnimations];
	[CATransaction begin];
	
	// set up the completion block; this sets the path
	[CATransaction setCompletionBlock:^{
		layer.path = path.CGPath;
		
		// now remove the animation
		[layer removeAnimationForKey:@"path"];
	}];
	
	// set up an animation
	CABasicAnimation *anim = [CABasicAnimation animationWithKeyPath:@"path"];
	anim.toValue = (__bridge id) path.CGPath;
	
	anim.duration = TSPathAnimationDuration;
	anim.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseInEaseOut];
	
	anim.fillMode = kCAFillModeBoth;
	anim.removedOnCompletion = NO;
	
	// add animation and commit transaction
	[layer addAnimation:anim forKey:anim.keyPath];
	[CATransaction commit];
}

#pragma mark - Button Actions
- (void)closeButtonClicked:(id)sender {
    self.hidden = true;
    [self removeFromSuperview];
}

#pragma mark Helpers
/**
 * Scales the input image by the "quality" factor, such that it can be
 * used to calculate a histogram. If no scaling is to be done (quality = 1)
 * the original image is returned.
 */
- (void) produceScaledVersionForHistogram {
	CGContextRef ctx;
	
	// Short-circuit if quality == 1
	if(self.quality <= 1) {
		return;
	}
	
	// Calculate scale factor
	CGFloat factor = 1.f / ((CGFloat) self.quality);
	
	CGSize newSize = CGSizeApplyAffineTransform(self.image.size, CGAffineTransformMakeScale(factor, factor));
	newSize.width = floor(newSize.width);
	newSize.height = floor(newSize.height);
	
	// Get information from the image
	CGImageRef cgImage = self.image.CGImage;
	CGColorSpaceRef colorSpace = CGImageGetColorSpace(cgImage);
	
	// Set up bitmap context
	ctx = CGBitmapContextCreate(nil, newSize.width, newSize.height, 8,
								(4 * newSize.width), colorSpace,
								(CGBitmapInfo) kCGImageAlphaNoneSkipLast);
	CGContextSetInterpolationQuality(ctx, kCGInterpolationHigh);
	CGContextSetAllowsAntialiasing(ctx, YES);
	
	CGColorSpaceRelease(colorSpace);
	
	// Draw the image in the newly created bitmap context
	CGRect destRect = {
		.size = newSize,
		.origin = CGPointZero
	};
	
	CGContextDrawImage(ctx, destRect, cgImage);
	
	// Create a CGImage from the context, then clean up
	CGImageRef scaledImage = CGBitmapContextCreateImage(ctx);
	CGContextRelease(ctx);
	
	// Done.
    self.image = [UIImage imageWithCGImage:scaledImage];
    CGImageRelease(scaledImage);
}

- (UIImage *)imageFromCVPixelBuffer:(CVPixelBufferRef)pixelBuffer{
    UIImage *image = nil;
    @autoreleasepool {
        CGImageRef cgImage = NULL;
        OSStatus res = CreateCGImageFromCVPixelBuffer(pixelBuffer,&cgImage);
        if (res == noErr){
            image= [UIImage imageWithCGImage:cgImage scale:1.0 orientation:UIImageOrientationUp];
        }
        CGImageRelease(cgImage);
    }
    return image;
}

static OSStatus CreateCGImageFromCVPixelBuffer(CVPixelBufferRef pixelBuffer, CGImageRef *imageOut)
{
    OSStatus err = noErr;
    OSType sourcePixelFormat;
    size_t width, height, sourceRowBytes;
    void *sourceBaseAddr = NULL;
    CGBitmapInfo bitmapInfo;
    CGColorSpaceRef colorspace = NULL;
    CGDataProviderRef provider = NULL;
    CGImageRef image = NULL;

    sourcePixelFormat = CVPixelBufferGetPixelFormatType( pixelBuffer );
    if ( kCVPixelFormatType_32ARGB == sourcePixelFormat )
        bitmapInfo = kCGBitmapByteOrder32Big | kCGImageAlphaNoneSkipFirst;
    else if ( kCVPixelFormatType_32BGRA == sourcePixelFormat )
        bitmapInfo = kCGBitmapByteOrder32Little | kCGImageAlphaNoneSkipFirst;
    else
        return -95014; // only uncompressed pixel formats

    sourceRowBytes = CVPixelBufferGetBytesPerRow( pixelBuffer );
    width = CVPixelBufferGetWidth( pixelBuffer );
    height = CVPixelBufferGetHeight( pixelBuffer );

    CVPixelBufferLockBaseAddress( pixelBuffer, 0 );
    sourceBaseAddr = CVPixelBufferGetBaseAddress( pixelBuffer );

    colorspace = CGColorSpaceCreateDeviceRGB();

    CVPixelBufferRetain( pixelBuffer );
    provider = CGDataProviderCreateWithData( (void *)pixelBuffer, sourceBaseAddr, sourceRowBytes * height, ReleaseCVPixelBuffer);
    image = CGImageCreate(width, height, 8, 32, sourceRowBytes, colorspace, bitmapInfo, provider, NULL, true, kCGRenderingIntentDefault);

    if ( err && image ) {
        CGImageRelease( image );
        image = NULL;
    }
    if ( provider ) CGDataProviderRelease( provider );
    if ( colorspace ) CGColorSpaceRelease( colorspace );
    *imageOut = image;
    return err;
}

static void ReleaseCVPixelBuffer(void *pixel, const void *data, size_t size)
{
    CVPixelBufferRef pixelBuffer = (CVPixelBufferRef)pixel;
    CVPixelBufferUnlockBaseAddress( pixelBuffer, 0 );
    CVPixelBufferRelease( pixelBuffer );
}

@end
