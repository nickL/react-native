/**
 * Copyright 2013 Facebook, Inc.
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 * http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 *
 * This pipes all of our console logging functions to native logging so that
 * JavaScript errors in required modules show up in Xcode via NSLog.
 *
 * @provides Object.es6
 * @polyfill
 */

// WARNING: This is an optimized version that fails on hasOwnProperty checks
// and non objects. It's not spec-compliant. It's a perf optimization.

Object.assign = function(target, sources) {
  if (__DEV__) {
    if (target == null) {
      throw new TypeError('Object.assign target cannot be null or undefined');
    }
    if (typeof target !== 'object' && typeof target !== 'function') {
      throw new TypeError(
        'In this environment the target of assign MUST be an object.' +
        'This error is a performance optimization and not spec compliant.'
      );
    }
  }

  for (var nextIndex = 1; nextIndex < arguments.length; nextIndex++) {
    var nextSource = arguments[nextIndex];
    if (nextSource == null) {
      continue;
    }

    if (__DEV__) {
      if (typeof nextSource !== 'object' &&
          typeof nextSource !== 'function') {
        throw new TypeError(
          'In this environment the target of assign MUST be an object.' +
          'This error is a performance optimization and not spec compliant.'
        );
      }
    }

    // We don't currently support accessors nor proxies. Therefore this
    // copy cannot throw. If we ever supported this then we must handle
    // exceptions and side-effects.

    for (var key in nextSource) {
      if (__DEV__) {
        var hasOwnProperty = Object.prototype.hasOwnProperty;
        if (!hasOwnProperty.call(nextSource, key)) {
          throw new TypeError(
            'One of the sources to assign has an enumerable key on the ' +
            'prototype chain. This is an edge case that we do not support. ' +
            'This error is a performance optimization and not spec compliant.'
          );
        }
      }
      target[key] = nextSource[key];
    }
  }

  return target;
};
