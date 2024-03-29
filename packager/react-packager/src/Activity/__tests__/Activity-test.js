jest.autoMockOff();

describe('Activity', function() {
  var Activity;

  var origConsoleLog = console.log;

  beforeEach(function() {
    console.log = jest.genMockFn();
    Activity = require('../');
  });

  afterEach(function() {
    console.log = origConsoleLog;
  });

  describe('startEvent', function() {
    it('writes a START event out to the console', function() {
      var EVENT_NAME = 'EVENT_NAME';
      var DATA = {someData: 42};

      Activity.startEvent(EVENT_NAME, DATA);
      jest.runOnlyPendingTimers();

      expect(console.log.mock.calls.length).toBe(1);
      var consoleMsg = console.log.mock.calls[0][0];
      expect(consoleMsg).toContain('START');
      expect(consoleMsg).toContain(EVENT_NAME);
      expect(consoleMsg).toContain(JSON.stringify(DATA));
    });
  });

  describe('endEvent', function() {
    it('writes an END event out to the console', function() {
      var EVENT_NAME = 'EVENT_NAME';
      var DATA = {someData: 42};

      var eventID = Activity.startEvent(EVENT_NAME, DATA);
      Activity.endEvent(eventID);
      jest.runOnlyPendingTimers();

      expect(console.log.mock.calls.length).toBe(2);
      var consoleMsg = console.log.mock.calls[1][0];
      expect(consoleMsg).toContain('END');
      expect(consoleMsg).toContain(EVENT_NAME);
      expect(consoleMsg).toContain(JSON.stringify(DATA));
    });

    it('throws when called with an invalid eventId', function() {
      expect(function() {
        Activity.endEvent(42);
      }).toThrow('event(42) is not a valid event id!');
    });

    it('throws when called with an expired eventId', function() {
      var eid = Activity.startEvent('', '');
      Activity.endEvent(eid);

      expect(function() {
        Activity.endEvent(eid);
      }).toThrow('event(1) has already ended!');
    });
  });

  describe('signal', function() {
    it('writes a SIGNAL event out to the console', function() {
      var EVENT_NAME = 'EVENT_NAME';
      var DATA = {someData: 42};

      Activity.signal(EVENT_NAME, DATA);
      jest.runOnlyPendingTimers();

      expect(console.log.mock.calls.length).toBe(1);
      var consoleMsg = console.log.mock.calls[0][0];
      expect(consoleMsg).toContain(EVENT_NAME);
      expect(consoleMsg).toContain(JSON.stringify(DATA));
    });
  });
});
