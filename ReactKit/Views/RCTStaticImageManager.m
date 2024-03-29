// Copyright 2004-present Facebook. All Rights Reserved.

#import "RCTStaticImageManager.h"

#import <UIKit/UIKit.h>

#import "RCTStaticImage.h"
#import "RCTConvert.h"

@implementation RCTStaticImageManager

- (UIView *)view
{
  return [[RCTStaticImage alloc] init];
}

RCT_EXPORT_VIEW_PROPERTY(capInsets)
RCT_REMAP_VIEW_PROPERTY(resizeMode, contentMode)

- (void)set_src:(id)json forView:(RCTStaticImage *)view withDefaultView:(RCTStaticImage *)defaultView
{
  if (json) {
    if ([[[json description] pathExtension] caseInsensitiveCompare:@"gif"] == NSOrderedSame) {
      [view.layer addAnimation:[RCTConvert GIF:json] forKey:@"contents"];
    } else {
      view.image = [RCTConvert UIImage:json];
    }
  } else {
    view.image = defaultView.image;
  }
}

- (void)set_tintColor:(id)json forView:(RCTStaticImage *)view withDefaultView:(RCTStaticImage *)defaultView
{
  if (json) {
    view.renderingMode = UIImageRenderingModeAlwaysTemplate;
    view.tintColor = [RCTConvert UIColor:json];
  } else {
    view.renderingMode = defaultView.renderingMode;
    view.tintColor = defaultView.tintColor;
  }
}

@end

