/**
 * Copyright 2004-present Facebook. All Rights Reserved.
 *
 * @providesModule ReactIOSEventEmitter
 * @typechecks static-only
 */

"use strict";

var EventPluginHub = require('EventPluginHub');
var ReactEventEmitterMixin = require('ReactEventEmitterMixin');
var ReactIOSTagHandles = require('ReactIOSTagHandles');
var NodeHandle = require('NodeHandle');
var EventConstants = require('EventConstants');

var merge = require('merge');
var warning = require('warning');

var topLevelTypes = EventConstants.topLevelTypes;

/**
 * Version of `ReactBrowserEventEmitter` that works on the receiving side of a
 * serialized worker boundary.
 */

// Shared default empty native event - conserve memory.
var EMPTY_NATIVE_EVENT = {};

/**
 * Selects a subsequence of `Touch`es, without destroying `touches`.
 *
 * @param {Array<Touch>} touches Deserialized touch objects.
 * @param {Array<number>} indices Indices by which to pull subsequence.
 * @return {Array<Touch>} Subsequence of touch objects.
 */
var touchSubsequence = function(touches, indices) {
  var ret = [];
  for (var i = 0; i < indices.length; i++) {
    ret.push(touches[indices[i]]);
  }
  return ret;
};

/**
 * TODO: Pool all of this.
 *
 * Destroys `touches` by removing touch objects at indices `indices`. This is
 * to maintain compatibility with W3C touch "end" events, where the active
 * touches don't include the set that has just been "ended".
 *
 * @param {Array<Touch>} touches Deserialized touch objects.
 * @param {Array<number>} indices Indices to remove from `touches`.
 * @return {Array<Touch>} Subsequence of removed touch objects.
 */
var removeTouchesAtIndices = function(touches, indices) {
  var rippedOut = [];
  for (var i = 0; i < indices.length; i++) {
    var index = indices[i];
    rippedOut.push(touches[index]);
    touches[index] = null;
  }
  var fillAt = 0;
  for (var j = 0; j < touches.length; j++) {
    var cur = touches[j];
    if (cur !== null) {
      touches[fillAt++] = cur;
    }
  }
  touches.length = fillAt;
  return rippedOut;
};

/**
 * `ReactIOSEventEmitter` is used to attach top-level event listeners. For example:
 *
 *   ReactIOSEventEmitter.putListener('myID', 'onClick', myFunction);
 *
 * This would allocate a "registration" of `('onClick', myFunction)` on 'myID'.
 *
 * @internal
 */
var ReactIOSEventEmitter = merge(ReactEventEmitterMixin, {

  registrationNames: EventPluginHub.registrationNameModules,

  putListener: EventPluginHub.putListener,

  getListener: EventPluginHub.getListener,

  deleteListener: EventPluginHub.deleteListener,

  deleteAllListeners: EventPluginHub.deleteAllListeners,

  /**
   * Internal version of `receiveEvent` in terms of normalized (non-tag)
   * `rootNodeID`.
   *
   * @see receiveEvent.
   *
   * @param {rootNodeID} rootNodeID React root node ID that event occured on.
   * @param {TopLevelType} topLevelType Top level type of event.
   * @param {object} nativeEventParam Object passed from native.
   */
  _receiveRootNodeIDEvent: function(rootNodeID, topLevelType, nativeEventParam) {
    var nativeEvent = nativeEventParam || EMPTY_NATIVE_EVENT;
    ReactIOSEventEmitter.handleTopLevel(
      topLevelType,
      rootNodeID,
      rootNodeID,
      nativeEvent
    );
  },

  /**
   * Publically exposed method on module for native objc to invoke when a top
   * level event is extracted.
   * @param {rootNodeID} rootNodeID React root node ID that event occured on.
   * @param {TopLevelType} topLevelType Top level type of event.
   * @param {object} nativeEventParam Object passed from native.
   */
  receiveEvent: function(tag, topLevelType, nativeEventParam) {
    var rootNodeID = ReactIOSTagHandles.tagToRootNodeID[tag];
    ReactIOSEventEmitter._receiveRootNodeIDEvent(
      rootNodeID,
      topLevelType,
      nativeEventParam
    );
  },

  /**
   * Simple multi-wrapper around `receiveEvent` that is intended to receive an
   * efficient representation of `Touch` objects, and other information that
   * can be used to construct W3C compliant `Event` and `Touch` lists.
   *
   * This may create dispatch behavior that differs than web touch handling. We
   * loop through each of the changed touches and receive it as a single event.
   * So two `touchStart`/`touchMove`s that occur simultaneously are received as
   * two separate touch event dispatches - when they arguably should be one.
   *
   * This implementation reuses the `Touch` objects themselves as the `Event`s
   * since we dispatch an event for each touch (though that might not be spec
   * compliant). The main purpose of reusing them is to save allocations.
   *
   * TODO: Dispatch multiple changed touches in one event. The bubble path
   * could be the first common ancestor of all the `changedTouches`.
   *
   * One difference between this behavior and W3C spec: cancelled touches will
   * not appear in `.touches`, or in any future `.touches`, though they may
   * still be "actively touching the surface".
   *
   * Web desktop polyfills only need to construct a fake touch event with
   * identifier 0, also abandoning traditional click handlers.
   */
  receiveTouches: function(eventTopLevelType, touches, changedIndices) {
    var changedTouches =
      eventTopLevelType === topLevelTypes.topTouchEnd ||
      eventTopLevelType === topLevelTypes.topTouchCancel ?
      removeTouchesAtIndices(touches, changedIndices) :
      touchSubsequence(touches, changedIndices);

    for (var jj = 0; jj < changedTouches.length; jj++) {
      var touch = changedTouches[jj];
      // Touch objects can fullfill the role of `DOM` `Event` objects if we set
      // the `changedTouches`/`touches`. This saves allocations.
      touch.changedTouches = changedTouches;
      touch.touches = touches;
      var nativeEvent = touch;
      var rootNodeID = null;
      var target = nativeEvent.target;
      if (target !== null && target !== undefined) {
        if (target < ReactIOSTagHandles.tagsStartAt) {
          // When we get multiple touches at the same time, only the first touch
          // actually has a view attached to it. The rest of the touches do not.
          // This is presumably because iOS doesn't want to send touch events to
          // two views for a single multi touch. Therefore this warning is only
          // appropriate when it happens to the first touch. (hence jj === 0)
          if (__DEV__) {
            if (jj === 0) {
              warning(
                false,
                'A view is reporting that a touch occured on tag zero.'
              );
            }
          }
          continue;
        } else {
          rootNodeID = NodeHandle.getRootNodeID(target);
        }
      }
      ReactIOSEventEmitter._receiveRootNodeIDEvent(
        rootNodeID,
        eventTopLevelType,
        nativeEvent
      );
    }
  }
});

module.exports = ReactIOSEventEmitter;
