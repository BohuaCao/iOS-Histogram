//
//  UIBezierPath+NarwalUtils.m
//  Narwal
//
//  Created by Kandao_user on 2020/12/11.
//

#import "UIBezierPath+NarwalUtils.h"

@implementation UIBezierPath (NarwalUtils)

/**
 * Produces a smooth, Hermite-interpolated curve between the first point
 * and all successive points; this is then appended to the existing path.
 *
 * @param points Array of CGPoint values, wrapped in NSValue.
 */
- (void) interpolatePointsWithHermite:(NSArray<NSValue *> *) points {
	CGFloat alpha = 1.f / 3.f;
	
	if(points.count == 0) {
		return;
	}
	
	// move to the first point in the path
	[self moveToPoint:points.firstObject.CGPointValue];
	
	NSInteger n = points.count - 1;
	
	for(NSInteger index = 0; index < n; index++) {
		// calculate first control point
		CGPoint currentPoint = [points[index] CGPointValue];
		NSInteger nextIndex = (index + 1) % points.count;
		NSInteger prevIndex = index == 0 ? points.count - 1 : index - 1;
	
		CGPoint previousPoint = points[prevIndex].CGPointValue;
		CGPoint nextPoint = points[nextIndex].CGPointValue;
		
		CGPoint endPoint = nextPoint;
		CGFloat mx = 0.f;
		CGFloat my = 0.f;
		
		if(index > 0) {
			mx = (nextPoint.x - previousPoint.x) / 2.f;
			my = (nextPoint.y - previousPoint.y) / 2.f;
		} else {
			mx = (nextPoint.x - currentPoint.x) / 2.f;
			my = (nextPoint.y - currentPoint.y) / 2.f;
		}
		
		CGPoint controlPoint1 = CGPointMake(currentPoint.x + mx * alpha, currentPoint.y + my * alpha);
		
		// calculate second control point
		currentPoint = points[nextIndex].CGPointValue;
		nextIndex = (nextIndex + 1) % points.count;
		prevIndex = index;
		
		previousPoint = points[prevIndex].CGPointValue;
		nextPoint = points[nextIndex].CGPointValue;
		
		if(index < (n - 1)) {
			mx = (nextPoint.x - previousPoint.x) / 2.f;
			my = (nextPoint.y - previousPoint.y) / 2.f;
		} else {
			mx = (currentPoint.x - previousPoint.x) / 2.f;
			my = (currentPoint.y - previousPoint.y) / 2.f;
		}
		
		CGPoint controlPoint2 = CGPointMake(currentPoint.x - mx * alpha, currentPoint.y - my * alpha);
		
		// add the curve
		[self addCurveToPoint:endPoint controlPoint1:controlPoint1 controlPoint2:controlPoint2];
	}
}

/**
 * Creates a CoreGraphics path from this path.
 */
- (CGPathRef) quartzPath {
	NSInteger numElements;
	
	// Need to begin a path here.
	CGPathRef immutablePath = NULL;
	
	// Then draw the path elements.
	numElements = self.count;
	if (numElements > 0) {
		CGMutablePathRef path = CGPathCreateMutable();
		BOOL didClosePath = YES;
		
		for (BezierElement *element in self.elements) {
			switch (element.elementType) {
                case kCGPathElementMoveToPoint:
					CGPathMoveToPoint(path, NULL, element.point.x, element.point.y);
					break;
					
                case kCGPathElementAddLineToPoint:
					CGPathAddLineToPoint(path, NULL, element.point.x, element.point.y);
					didClosePath = NO;
					break;
					
                case kCGPathElementAddCurveToPoint:
					CGPathAddCurveToPoint(path, NULL, element.point.x, element.point.y,
                                          element.controlPoint1.x, element.controlPoint1.y,
                                          element.controlPoint2.x, element.controlPoint2.y);
					didClosePath = NO;
					break;
					
                case kCGPathElementCloseSubpath:
					CGPathCloseSubpath(path);
					didClosePath = YES;
					break;
                    
                default:
                    break;
			}
		}
		
		// Be sure the path is closed or Quartz may not do valid hit detection.
		if (!didClosePath) {
			CGPathCloseSubpath(path);
		}
		
		immutablePath = CGPathCreateCopy(path);
		CGPathRelease(path);
	}
	
	return immutablePath;
}

@end
