
jest.dontMock('../')
    .dontMock('q')
    .setMock('../../ModuleDescriptor', function(data) {return data;});

var q = require('q');

describe('HasteDependencyResolver', function() {
  var HasteDependencyResolver;
  var DependencyGraph;

  beforeEach(function() {
    // For the polyfillDeps
    require('path').join.mockImpl(function(a, b) {
      return b;
    });
    HasteDependencyResolver = require('../');
    DependencyGraph = require('../DependencyGraph');
  });

  describe('getDependencies', function() {
    pit('should get dependencies with polyfills', function() {
      var module = {id: 'index', path: '/root/index.js', dependencies: ['a']};
      var deps = [module];

      var depResolver = new HasteDependencyResolver({
        projectRoot: '/root'
      });

      // Is there a better way? How can I mock the prototype instead?
      var depGraph = depResolver._depGraph;
      depGraph.getOrderedDependencies.mockImpl(function() {
        return deps;
      });
      depGraph.load.mockImpl(function() {
        return q();
      });

      return depResolver.getDependencies('/root/index.js')
        .then(function(result) {
          expect(result.mainModuleId).toEqual('index');
          expect(result.dependencies).toEqual([
            { path: 'polyfills/prelude.js',
              id: 'polyfills/prelude.js',
              isPolyfill: true,
              dependencies: []
            },
            { path: 'polyfills/require.js',
              id: 'polyfills/require.js',
              isPolyfill: true,
              dependencies: ['polyfills/prelude.js']
            },
            { path: 'polyfills/polyfills.js',
              id: 'polyfills/polyfills.js',
              isPolyfill: true,
              dependencies: ['polyfills/prelude.js', 'polyfills/require.js']
            },
            module
          ]);
        });
    });

    pit('should pass in more polyfills', function() {
      var module = {id: 'index', path: '/root/index.js', dependencies: ['a']};
      var deps = [module];

      var depResolver = new HasteDependencyResolver({
        projectRoot: '/root',
        polyfillModuleNames: ['some module']
      });

      // Is there a better way? How can I mock the prototype instead?
      var depGraph = depResolver._depGraph;
      depGraph.getOrderedDependencies.mockImpl(function() {
        return deps;
      });
      depGraph.load.mockImpl(function() {
        return q();
      });

      return depResolver.getDependencies('/root/index.js')
        .then(function(result) {
          expect(result.mainModuleId).toEqual('index');
          expect(result.dependencies).toEqual([
            { path: 'polyfills/prelude.js',
              id: 'polyfills/prelude.js',
              isPolyfill: true,
              dependencies: []
            },
            { path: 'polyfills/require.js',
              id: 'polyfills/require.js',
              isPolyfill: true,
              dependencies: ['polyfills/prelude.js']
            },
            { path: 'polyfills/polyfills.js',
              id: 'polyfills/polyfills.js',
              isPolyfill: true,
              dependencies: ['polyfills/prelude.js', 'polyfills/require.js']
            },
            { path: 'some module',
              id: 'some module',
              isPolyfill: true,
              dependencies: [ 'polyfills/prelude.js', 'polyfills/require.js',
                'polyfills/polyfills.js']
            },
            module
          ]);
        });
    });
  });

  describe('wrapModule', function() {
    it('should ', function() {
      var depResolver = new HasteDependencyResolver({
        projectRoot: '/root'
      });

      var depGraph = depResolver._depGraph;
      var dependencies = ['x', 'y', 'z']
      var code = [
        'require("x")',
        'require("y")',
        'require("z")',
      ].join('\n');

      depGraph.resolveDependency.mockImpl(function(fromModule, toModuleName) {
        if (toModuleName === 'x') {
          return {
            id: 'changed'
          };
        } else if (toModuleName === 'y') {
          return { id: 'y' };
        }
        return null;
      });

      var processedCode = depResolver.wrapModule({
        id: 'test module',
        path: '/root/test.js',
        dependencies: dependencies
      }, code);

      expect(processedCode).toEqual([
        "__d('test module',[\"changed\",\"y\"],function(global," +
        " require, requireDynamic, requireLazy, module, exports) {" +
        "  require('changed')",
        "require('y')",
        'require("z")});',
      ].join('\n'));
    });
  });
});
