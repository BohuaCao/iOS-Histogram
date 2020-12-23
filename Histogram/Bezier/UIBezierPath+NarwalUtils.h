//
//  UIBezierPath+NarwalUtils.h
//  Narwal
//
//  Created by Kandao_user on 2020/12/11.
//

#import "UIBezierPath+Elements.h"

@interface UIBezierPath (NarwalUtils)

/**
 * Produces a smooth, Hermite-interpolated curve between the first point
 * and all successive points; this is then appended to the existing path.
 *
 * @param points Array of NSPoint values, wrapped in NSValue.
 */
- (void) interpolatePointsWithHermite:(NSArray<NSValue *> *) points;

/// CoreGraphics path
@property (nonatomic, readonly, getter=quartzPath) CGPathRef CGPath;

@end
