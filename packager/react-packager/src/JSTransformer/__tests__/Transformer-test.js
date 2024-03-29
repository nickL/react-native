'use strict';

jest
  .dontMock('worker-farm')
  .dontMock('q')
  .dontMock('os')
  .dontMock('../index');

describe('Transformer', function() {
  var Transformer;
  var workers;

  beforeEach(function() {
    workers = jest.genMockFn();
    jest.setMock('worker-farm', jest.genMockFn().mockImpl(function() {
      return workers;
    }));
    require('../Cache').prototype.get.mockImpl(function(filePath, callback) {
      return callback();
    });
    require('fs').readFile.mockImpl(function(file, callback) {
      callback(null, 'content');
    });
    Transformer = require('../');
  });

  pit('should loadFileAndTransform', function() {
    workers.mockImpl(function(data, callback) {
      callback(null, { code: 'transformed' });
    });
    require('fs').readFile.mockImpl(function(file, callback) {
      callback(null, 'content');
    });

    return new Transformer({}).loadFileAndTransform([], 'file', {})
      .then(function(data) {
        expect(data).toEqual({
          code: 'transformed',
          sourcePath: 'file',
          sourceCode: 'content'
        });
      });
  });

  pit('should add file info to parse errors', function() {
    require('fs').readFile.mockImpl(function(file, callback) {
      callback(null, 'var x;\nvar answer = 1 = x;');
    });

    workers.mockImpl(function(data, callback) {
      var esprimaError = new Error('Error: Line 2: Invalid left-hand side in assignment');
      esprimaError.description = 'Invalid left-hand side in assignment';
      esprimaError.lineNumber = 2;
      esprimaError.column = 15;
      callback(null, {error: esprimaError});
    });

    return new Transformer({}).loadFileAndTransform([], 'foo-file.js', {})
      .catch(function(error) {
        expect(error.type).toEqual('TransformError');
        expect(error.snippet).toEqual([
          'var answer = 1 = x;',
          '             ^',
        ].join('\n'));
      });
  });
});
