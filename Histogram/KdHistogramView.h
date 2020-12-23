//
//  KdHistogramView.h
//  Narwal
//
//  Created by Kandao_user on 2020/12/11.
//

#import <UIKit/UIKit.h>

@interface KdHistogramView : UIView

+ (instancetype)showInView:(UIView *)view;
+ (void)hideForView:(UIView *)view;

/// update histogram with pixel buffer
/// @param pixelBuffer buffer
- (void)updateWithPixelBuffer:(CVPixelBufferRef)pixelBuffer;

/// update image and quality
/// @param image image
/// @param quality quality
- (void)updateImage:(UIImage *)image andQuality:(NSUInteger)quality;

@end
