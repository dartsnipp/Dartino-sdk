// Copyright (c) 2015, the Dartino project authors. Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE.md file.

library dartino.vm_session;

import 'dart:core';
import 'dart:async';
import 'dart:convert';
import 'dart:io' hide exit;

import 'dart:typed_data' show
    ByteData,
    Uint8List;

import 'vm_commands.dart';
import 'dartino_system.dart';

import 'dartino_class.dart' show
    DartinoClass;

import 'incremental/dartino_compiler_incremental.dart'
    show IncrementalCompiler;

import 'src/codegen_visitor.dart';
import 'src/debug_info.dart';

// TODO(ahe): Get rid of this import.
import 'src/dartino_backend.dart' show DartinoBackend;

import 'src/dartino_selector.dart' show
    DartinoSelector,
    SelectorKind;

import 'debug_state.dart';

import 'src/shared_command_infrastructure.dart' show
    CommandTransformerBuilder,
    toUint8ListView;

import 'src/hub/session_manager.dart' show
    SessionState;

import 'package:dartino_compiler/program_info.dart' show
    Configuration;

part 'vm_command_reader.dart';
part 'input_handler.dart';

/// Encapsulates a TCP connection to a running dartino-vm and provides a
/// [VmCommand] based view on top of it.
class DartinoVmSession {
  /// The outgoing connection to the dartino-vm.
  final StreamSink<List<int>> _outgoingSink;

  final Sink<List<int>> stdoutSink;
  final Sink<List<int>> stderrSink;

  /// The VM command reader reads data from the vm, converts the data
  /// into a [VmCommand], and provides a stream iterator iterating over
  /// these commands.
  /// If the [VmCommand] is for stdout or stderr the reader automatically
  /// forwards them to the stdout/stderr sinks and does not add them to the
  /// iterator.
  final VmCommandReader _commandReader;

  /// Completes when the underlying TCP connection is terminated.
  final Future _done;

  bool _connectionIsDead = false;
  bool _drainedIncomingCommands = false;

  // TODO(ahe): Get rid of this. See also issue 67.
  bool silent = false;

  /// When true, messages generated by this class (or its subclasses) will not
  /// contain IDs. Note: we only hide these IDs for debugger tests that use
  /// golden files.
  bool hideRawIds = false;

  /// When true, don't use colors to highlight focus when printing code.
  /// This is currently only true when running tests to avoid having to deal
  /// with color control characters in the expected files.
  bool colorsDisabled = false;

  VmCommand connectionError = new ConnectionError("Connection is closed", null);

  DartinoVmSession(Socket vmSocket,
                  Sink<List<int>> stdoutSink,
                  Sink<List<int>> stderrSink)
      : _outgoingSink = vmSocket,
        this.stdoutSink = stdoutSink,
        this.stderrSink = stderrSink,
        _done = vmSocket.done,
        _commandReader = new VmCommandReader(vmSocket, stdoutSink, stderrSink) {
    _done.catchError((_, __) {}).then((_) {
      _connectionIsDead = true;
    });
  }

  void writeStdout(String s) {
    if (!silent && stdoutSink != null) stdoutSink.add(UTF8.encode(s));
  }

  void writeStdoutLine(String s) => writeStdout("$s\n");

  /// Convenience around [runCommands] for running just a single command.
  Future<VmCommand> runCommand(VmCommand command) {
    return runCommands([command]);
  }

  /// Sends the given commands to a dartino-vm and reads response commands
  /// (if necessary).
  ///
  /// If all commands have been successfully applied and responses been awaited,
  /// this function will complete with the last received [VmCommand] from the
  /// remote peer (or `null` if there was none).
  Future<VmCommand> runCommands(List<VmCommand> commands) async {
    if (commands.any((VmCommand c) => c.numberOfResponsesExpected == null)) {
      throw new ArgumentError(
          'The runComands() method will read response commands and therefore '
          'needs to know how many to read. One of the given commands does'
          'not specify how many commands the response will have.');
    }

    VmCommand lastResponse;
    for (VmCommand command in commands) {
      await sendCommand(command);
      for (int i = 0; i < command.numberOfResponsesExpected; i++) {
        lastResponse = await readNextCommand();
      }
    }
    return lastResponse;
  }

  /// Sends all given [VmCommand]s to a dartino-vm.
  Future sendCommands(List<VmCommand> commands) async {
    for (var command in commands) {
      await sendCommand(command);
    }
  }

  /// Sends a [VmCommand] to a dartino-vm.
  Future sendCommand(VmCommand command) async {
    if (_connectionIsDead) {
      throw new StateError(
          'Trying to send command ${command} to dartino-vm, but '
          'the connection is already closed.');
    }
    command.addTo(_outgoingSink);
  }

  /// Will read the next [VmCommand] the dartino-vm sends to us.
  Future<VmCommand> readNextCommand({bool force: true}) async {
    if (_drainedIncomingCommands) {
      return connectionError;
    }

    _drainedIncomingCommands = !await _commandReader.iterator.moveNext()
        .catchError((error, StackTrace trace) {
          connectionError = new ConnectionError(error, trace);
          return false;
        });

    if (_drainedIncomingCommands && force) {
      return connectionError;
    }

    return _commandReader.iterator.current;
  }

  /// Closes the connection to the dartino-vm and drains the remaining response
  /// commands.
  ///
  /// If [ignoreExtraCommands] is `false` it will throw a StateError if the
  /// dartino-vm sent any commands.
  Future shutdown({bool ignoreExtraCommands: false}) async {
    await _outgoingSink.close().catchError((_) {});

    while (!_drainedIncomingCommands) {
      VmCommand response = await readNextCommand(force: false);
      if (!ignoreExtraCommands && response != null) {
        await kill();
        throw new StateError(
            "Got unexpected command from dartino-vm during shutdown "
            "($response)");
      }
    }

    return _done;
  }

  Future interrupt() {
    return sendCommand(const ProcessDebugInterrupt());
  }

  /// Closes the connection to the dartino-vm. It does not wait until it shuts
  /// down.
  ///
  /// This method will never complete with an exception.
  Future kill() async {
    _connectionIsDead = true;
    _drainedIncomingCommands = true;

    await _outgoingSink.close().catchError((_) {});
    var value = _commandReader.iterator.cancel();
    if (value != null) {
      await value.catchError((_) {});
    }
    _drainedIncomingCommands = true;
  }
}

/// Extends a bare [DartinoVmSession] with debugging functionality.
class Session extends DartinoVmSession {
  final IncrementalCompiler compiler;
  final Future processExitCodeFuture;

  DebugState debugState;
  DartinoSystem dartinoSystem;
  bool loaded = false;
  bool running = false;
  bool terminated = false;

  Configuration configuration;

  Session(Socket dartinoVmSocket,
          this.compiler,
          Sink<List<int>> stdoutSink,
          Sink<List<int>> stderrSink,
          [this.processExitCodeFuture])
      : super(dartinoVmSocket, stdoutSink, stderrSink) {
    // We send many small packages, so use no-delay.
    dartinoVmSocket.setOption(SocketOption.TCP_NODELAY, true);
    // TODO(ajohnsen): Should only be initialized on debug()/testDebugger().
    debugState = new DebugState(this);
  }

  Future applyDelta(DartinoDelta delta) async {
    VmCommand response = await runCommands(delta.commands);
    dartinoSystem = delta.system;
    return response;
  }

  Future<HandShakeResult> handShake(String version) async {
    VmCommand command = await runCommand(new HandShake(version));
    if (command != null && command is HandShakeResult) return command;
    return null;
  }

  Future disableVMStandardOutput() async {
    await runCommand(const DisableStandardOutput());
  }

  // Returns either a [WriteSnapshotResult] or a [ConnectionError].
  Future<VmCommand> writeSnapshot(String snapshotPath) async {
    VmCommand result = await runCommand(new WriteSnapshot(snapshotPath));
    await shutdown();
    return result;
  }

  // Enable support for live-editing commands. This must be called prior to
  // sending deltas or if the program termination behavior is to be observed.
  // TODO(zerny): Separate termination observation from live editing.
  Future enableLiveEditing() async {
    await runCommand(const LiveEditing());
  }

  // Enable support for debugging commands. This must be called prior to setting
  // breakpoints. Currently debugging support entails live editing, but that
  // will not continue to be the case once support for attaching to VMs running
  // read-only programs has been added.
  // TODO(zerny): Separate debugging from live editing.
  Future enableDebugger() async {
    await enableLiveEditing();
    await runCommand(const Debugging());
  }

  Future spawnProcess(List<String> arguments) async {
    await runCommand(new ProcessSpawnForMain(arguments));
  }

  Future run(List<String> arguments) async {
    await spawnProcess(arguments);
    loaded = true;
    await runCommand(const ProcessRun());
    // NOTE: The [ProcessRun] command normally results in a
    // [ProcessTerminated] command. But if the compiler emitted a compile time
    // error, the dartino-vm will just halt()/exit() and we therefore get no
    // response.
    var command = await readNextCommand(force: false);
    if (command != null && command is! ProcessTerminated) {
      throw new Exception('Expected process to finish complete with '
                          '[ProcessTerminated] but got [$command]');
    }
    await shutdown();
  }

  Future<int> debug(
      Stream<String> inputLines,
      Uri base,
      SessionState state,
      {bool echo: false}) async {
    await enableDebugger();
    // TODO(ahe): Arguments?
    await spawnProcess([]);
    return new InputHandler(this, inputLines, echo, base).run(state);
  }

  Future terminateSession() async {
    await runCommand(const SessionEnd());
    if (processExitCodeFuture != null) await processExitCodeFuture;
    await shutdown();
    terminated = true;
  }

  // This method handles the various responses a command can return to indicate
  // the process has stopped running.
  // The session's state is updated to match the current state of the vm.
  Future<VmCommand> handleProcessStop(VmCommand response) async {
    debugState.reset();
    switch (response.code) {
      case VmCommandCode.UncaughtException:
      case VmCommandCode.ProcessCompileTimeError:
        running = false;
        break;

      case VmCommandCode.ProcessTerminated:
        running = false;
        loaded = false;
        // TODO(ahe): Let the caller terminate the session. See issue 67.
        await terminateSession();
        break;

      case VmCommandCode.ConnectionError:
        running = false;
        loaded = false;
        await shutdown();
        terminated = true;
        break;

      case VmCommandCode.ProcessBreakpoint:
        ProcessBreakpoint command = response;
        debugState.currentProcess = command.processId;
        var function = dartinoSystem.lookupFunctionById(command.functionId);
        debugState.topFrame = new BackTraceFrame(
            function, command.bytecodeIndex, compiler, debugState);
        running = true;
        break;

      default:
        throw new StateError(
            "Unhandled response from Dartino VM connection: ${response.code}");

    }
    return response;
  }

  Future<VmCommand> debugRun() async {
    assert(!loaded);
    assert(!running);
    loaded = true;
    running = true;
    await sendCommand(const ProcessRun());
    return handleProcessStop(await readNextCommand());
  }

  Future setBreakpointHelper(String name,
                             DartinoFunction function,
                             int bytecodeIndex) async {
    ProcessSetBreakpoint response = await runCommands([
        new PushFromMap(MapId.methods, function.functionId),
        new ProcessSetBreakpoint(bytecodeIndex),
    ]);
    int breakpointId = response.value;
    var breakpoint = new Breakpoint(function, bytecodeIndex, breakpointId);
    debugState.breakpoints[breakpointId] = breakpoint;
    return breakpoint;
  }

  // TODO(ager): Let setBreakpoint return a stream instead and deal with
  // error situations such as bytecode indices that are out of bounds for
  // some of the methods with the given name.
  Future setBreakpoint({String methodName, int bytecodeIndex}) async {
    Iterable<DartinoFunction> functions =
        dartinoSystem.functionsWhere((f) => f.name == methodName);
    List<Breakpoint> breakpoints = [];
    for (DartinoFunction function in functions) {
      breakpoints.add(
          await setBreakpointHelper(methodName, function, bytecodeIndex));
    }
    return breakpoints;
  }

  Future setFileBreakpointFromPosition(String name,
                                       Uri file,
                                       int position) async {
    if (position == null) {
      return null;
    }
    DebugInfo debugInfo = compiler.debugInfoForPosition(
        file,
        position,
        dartinoSystem);
    if (debugInfo == null) {
      return null;
    }
    SourceLocation location = debugInfo.locationForPosition(position);
    if (location == null) {
      return null;
    }
    DartinoFunction function = debugInfo.function;
    int bytecodeIndex = location.bytecodeIndex;
    return setBreakpointHelper(function.name, function, bytecodeIndex);
  }

  Future setFileBreakpointFromPattern(Uri file,
                                      int line,
                                      String pattern) async {
    assert(line > 0);
    int position = compiler.positionInFileFromPattern(file, line - 1, pattern);
    return setFileBreakpointFromPosition(
        '$file:$line:$pattern', file, position);
  }

  Future setFileBreakpoint(Uri file, int line, int column) async {
    assert(line > 0 && column > 0);
    int position = compiler.positionInFile(file, line - 1, column - 1);
    return setFileBreakpointFromPosition('$file:$line:$column', file, position);
  }

  Future doDeleteOneShotBreakpoint(int processId, int breakpointId) async {
    ProcessDeleteBreakpoint response = await runCommand(
        new ProcessDeleteOneShotBreakpoint(processId, breakpointId));
    assert(response.id == breakpointId);
  }

  Future<Breakpoint> deleteBreakpoint(int id) async {
    if (!debugState.breakpoints.containsKey(id)) {
      return null;
    }
    ProcessDeleteBreakpoint response =
        await runCommand(new ProcessDeleteBreakpoint(id));
    assert(response.id == id);
    return debugState.breakpoints.remove(id);
  }

  List<Breakpoint> breakpoints() {
    assert(debugState.breakpoints != null);
    return debugState.breakpoints.values.toList();
  }

  Iterable<Uri> findSourceFiles(Pattern pattern) {
    return compiler.findSourceFiles(pattern);
  }

  bool stepMadeProgress(BackTraceFrame frame) {
    return frame.functionId != debugState.topFrame.functionId ||
        frame.bytecodePointer != debugState.topFrame.bytecodePointer;
  }

  Future<VmCommand> stepTo(int functionId, int bcp) async {
    assert(running);
    VmCommand response = await runCommand(new ProcessStepTo(functionId, bcp));
    return handleProcessStop(response);
  }

  Future<VmCommand> step() async {
    assert(running);
    final SourceLocation previous = debugState.currentLocation;
    final BackTraceFrame initialFrame = debugState.topFrame;
    VmCommand response;
    do {
      int bcp = debugState.topFrame.stepBytecodePointer(previous);
      if (bcp != -1) {
        response = await stepTo(debugState.topFrame.functionId, bcp);
      } else {
        response = await stepBytecode();
      }
    } while (running &&
             debugState.atLocation(previous) &&
             stepMadeProgress(initialFrame));
    return response;
  }

  Future<VmCommand> stepOver() async {
    assert(running);
    VmCommand response;
    final SourceLocation previous = debugState.currentLocation;
    final BackTraceFrame initialFrame = debugState.topFrame;
    do {
      response = await stepOverBytecode();
    } while (running &&
             debugState.atLocation(previous) &&
             stepMadeProgress(initialFrame));
    return response;
  }

  Future<VmCommand> stepOut() async {
    assert(running);
    BackTrace trace = await backTrace();
    // If we are at the last frame, just continue. This will either terminate
    // the process or stop at any user configured breakpoints.
    if (trace.visibleFrames <= 1) return cont();

    // Since we know there is at least two visible frames at this point stepping
    // out will hit a visible frame before the process terminates, hence we can
    // step out until we either hit another breakpoint or a visible frame, ie.
    // we skip internal frame and stop at the next visible frame.
    SourceLocation return_location = trace.visibleFrame(1).sourceLocation();
    VmCommand response;
    int processId = debugState.currentProcess;
    do {
      await sendCommand(const ProcessStepOut());
      ProcessSetBreakpoint setBreakpoint = await readNextCommand();
      assert(setBreakpoint.value != -1);

      // handleProcessStop resets the debugState and sets the top frame if it
      // hits either the above setBreakpoint or another breakpoint.
      response = await handleProcessStop(await readNextCommand());
      bool success =
          response is ProcessBreakpoint &&
          response.breakpointId == setBreakpoint.value;
      if (!success) {
        await doDeleteOneShotBreakpoint(processId, setBreakpoint.value);
        return response;
      }
    } while (!debugState.topFrame.isVisible);
    if (running && debugState.atLocation(return_location)) {
      response = await step();
    }
    return response;
  }

  Future<VmCommand> restart() async {
    assert(loaded);
    assert(debugState.currentBackTrace != null);
    assert(debugState.currentBackTrace.length > 1);
    int frame = debugState.actualCurrentFrameNumber;
    return handleProcessStop(await runCommand(new ProcessRestartFrame(frame)));
  }

  Future<VmCommand> stepBytecode() async {
    assert(running);
    return handleProcessStop(await runCommand(const ProcessStep()));
  }

  Future<VmCommand> stepOverBytecode() async {
    assert(running);
    int processId = debugState.currentProcess;
    await sendCommand(const ProcessStepOver());
    ProcessSetBreakpoint setBreakpoint = await readNextCommand();
    VmCommand response = await handleProcessStop(await readNextCommand());
    bool success =
        response is ProcessBreakpoint &&
        response.breakpointId == setBreakpoint.value;
    if (!success && !terminated && setBreakpoint.value != -1) {
      // Delete the initial one-time breakpoint as it wasn't hit.
      await doDeleteOneShotBreakpoint(processId, setBreakpoint.value);
    }
    return response;
  }

  Future<VmCommand> cont() async {
    assert(running);
    return handleProcessStop(await runCommand(const ProcessContinue()));
  }

  bool selectFrame(int frame) {
    if (debugState.currentBackTrace == null ||
        debugState.currentBackTrace.actualFrameNumber(frame) == -1) {
      return false;
    }
    debugState.currentFrame = frame;
    return true;
  }

  BackTrace stackTraceFromBacktraceResponse(
      ProcessBacktrace backtraceResponse) {
    int frames = backtraceResponse.frames;
    BackTrace stackTrace = new BackTrace(frames, debugState);
    for (int i = 0; i < frames; ++i) {
      int functionId = backtraceResponse.functionIds[i];
      DartinoFunction function = dartinoSystem.lookupFunctionById(functionId);
      if (function == null) {
        function = const DartinoFunction.missing();
      }
      stackTrace.addFrame(
          compiler,
          new BackTraceFrame(function,
                         backtraceResponse.bytecodeIndices[i],
                         compiler,
                         debugState));
    }
    return stackTrace;
  }

  Future<RemoteObject> uncaughtException() async {
    assert(loaded);
    assert(!terminated);
    if (debugState.currentUncaughtException == null) {
      await sendCommand(const ProcessUncaughtExceptionRequest());
      VmCommand response = await readNextCommand();
      if (response is DartValue) {
        debugState.currentUncaughtException = new RemoteValue(response);
      } else {
        assert(response is InstanceStructure);
        List<DartValue> fields = await readInstanceStructureFields(response);
        debugState.currentUncaughtException =
            new RemoteInstance(response, fields);
      }
    }
    return debugState.currentUncaughtException;
  }

  Future<BackTrace> backTrace() async {
    assert(loaded);
    if (debugState.currentBackTrace == null) {
      ProcessBacktrace backtraceResponse =
          await runCommand(
              new ProcessBacktraceRequest(debugState.currentProcess));
      debugState.currentBackTrace =
          stackTraceFromBacktraceResponse(backtraceResponse);
    }
    return debugState.currentBackTrace;
  }

  Future<BackTrace> backtraceForFiber(int fiber) async {
    ProcessBacktrace backtraceResponse =
        await runCommand(new ProcessFiberBacktraceRequest(fiber));
    return stackTraceFromBacktraceResponse(backtraceResponse);
  }

  Future<List<BackTrace>> fibers() async {
    assert(running);
    await runCommand(const NewMap(MapId.fibers));
    ProcessNumberOfStacks response =
        await runCommand(const ProcessAddFibersToMap());
    int numberOfFibers = response.value;
    List<BackTrace> stacktraces = new List(numberOfFibers);
    for (int i = 0; i < numberOfFibers; i++) {
      stacktraces[i] = await backtraceForFiber(i);
    }
    await runCommand(const DeleteMap(MapId.fibers));
    return stacktraces;
  }

  Future<List<int>> processes() async {
    assert(running);
    ProcessGetProcessIdsResult response =
      await runCommand(const ProcessGetProcessIds());
    return response.ids;
  }

  Future<BackTrace> processStack(int processId) async {
    assert(running);
    ProcessBacktrace backtraceResponse =
      await runCommand(new ProcessBacktraceRequest(processId));
    return stackTraceFromBacktraceResponse(backtraceResponse);
  }

  String dartValueToString(DartValue value) {
    if (value is Instance) {
      Instance i = value;
      String className = dartinoSystem.lookupClassById(i.classId).name;
      return "Instance of '$className'";
    } else {
      return value.dartToString();
    }
  }

  String instanceStructureToString(InstanceStructure structure,
                                   List<DartValue> fields) {
    int classId = structure.classId;
    DartinoClass klass = dartinoSystem.lookupClassById(classId);

    // TODO(dartino_compiler-team): This should be more strict and a compiler
    // bug should be reported to the user in order for us to get a bugreport.
    if (klass == null) {
      return 'Unknown (Dartino compiler was unable to find exception class)';
    }

    StringBuffer sb = new StringBuffer();
    sb.writeln("Instance of '${klass.name}' {");
    for (int i = 0; i < structure.fields; i++) {
      DartValue value = fields[i];
      String fieldName = debugState.lookupFieldName(klass, i);
      if (fieldName == null) {
        fieldName = '<unnamed>';
      }
      sb.writeln('  $fieldName: ${dartValueToString(value)}');
    }
    sb.write('}');
    return '$sb';
  }

  String noSuchMethodErrorToString(List<DartValue> nsmFields) {
    assert(nsmFields.length == 3);
    DartValue receiver = nsmFields[0];
    ClassValue receiverClass = nsmFields[1];
    Integer receiverSelector = nsmFields[2];
    DartinoSelector selector = new DartinoSelector(receiverSelector.value);

    String method =
        dartinoSystem.lookupSymbolBySelector(selector.encodedSelector);
    DartinoClass klass = dartinoSystem.lookupClassById(receiverClass.classId);
    // TODO(ahe): If DartinoClass is a synthetic closure class, improve the
    // message. For example, "(local) function `foo` takes 3 arguments, but
    // called with 4" instead of "Class '<internal>' has no method named 'call'
    // that takes 4 arguments".
    String name = klass.name;
    String raw = hideRawIds
        ? "" : " (${receiverClass.classId}::${selector.encodedSelector})";
    // TODO(ahe): Lookup the name in the receiverClass and include that as a
    // suggestion in the error mesage.
    switch (selector.kind) {
      case SelectorKind.Method:
        return "NoSuchMethodError: Class '$name' has no method named "
            "'$method' that takes ${selector.arity} arguments$raw";

      case SelectorKind.Getter:
        return "NoSuchMethodError: "
            "Class '$name' has no getter named '$method'$raw";

      case SelectorKind.Setter:
        return "NoSuchMethodError: "
            "Class '$name' has no setter named '$method'$raw";
    }
  }

  Future<List<DartValue>> readInstanceStructureFields(
      InstanceStructure structure) async {
    List<DartValue> fields = <DartValue>[];
    for (int i = 0; i < structure.fields; i++) {
      fields.add(await readNextCommand());
    }
    return fields;
  }

  String exceptionToString(RemoteObject exception) {
    String message;
    if (exception is RemoteValue) {
      message = dartValueToString(exception.value);
    } else if (exception is RemoteInstance) {
      InstanceStructure structure = exception.instance;
      int classId = structure.classId;
      DartinoClass klass = dartinoSystem.lookupClassById(classId);

      DartinoBackend backend = compiler.compiler.backend;
      var dartinoNoSuchMethodErrorClass = dartinoSystem.lookupClassByElement(
          backend.dartinoNoSuchMethodErrorClass);

      if (klass == dartinoNoSuchMethodErrorClass) {
        message = noSuchMethodErrorToString(exception.fields);
      } else {
        message = instanceStructureToString(
            exception.instance, exception.fields);
      }
    } else {
      throw new UnimplementedError();
    }
    return 'Uncaught exception: $message';
  }

  Future<RemoteValue> processVariable(String name) async {
    assert(loaded);
    LocalValue local = await lookupValue(name);
    return local != null ? await processLocal(local) : null;
  }

  Future<RemoteObject> processVariableStructure(String name) async {
    assert(loaded);
    LocalValue local = await lookupValue(name);
    return local != null ? await processLocalStructure(local) : null;
  }

  Future<List<RemoteObject>> processAllVariables() async {
    assert(loaded);
    BackTrace trace = await backTrace();
    ScopeInfo info = trace.scopeInfoForCurrentFrame;
    List<RemoteObject> variables = [];
    for (ScopeInfo current = info;
         current != ScopeInfo.sentinel;
         current = current.previous) {
      variables.add(await processLocal(current.local, current.name));
    }
    return variables;
  }

  Future<LocalValue> lookupValue(String name) async {
    assert(loaded);
    BackTrace trace = await backTrace();
    return trace.scopeInfoForCurrentFrame.lookup(name);
  }

  Future<RemoteValue> processLocal(LocalValue local, [String name]) async {
    var actualFrameNumber = debugState.actualCurrentFrameNumber;
    VmCommand response = await runCommand(
        new ProcessLocal(actualFrameNumber, local.slot));
    assert(response is DartValue);
    return new RemoteValue(response, name: name);
  }

  Future<RemoteObject> processLocalStructure(LocalValue local) async {
    var frameNumber = debugState.actualCurrentFrameNumber;
    await sendCommand(new ProcessLocalStructure(frameNumber, local.slot));
    VmCommand response = await readNextCommand();
    if (response is DartValue) {
      return new RemoteValue(response);
    } else {
      assert(response is InstanceStructure);
      List<DartValue> fields = await readInstanceStructureFields(response);
      return new RemoteInstance(response, fields);
    }
  }

  String remoteObjectToString(RemoteObject object) {
    String message;
    if (object is RemoteValue) {
      message = dartValueToString(object.value);
    } else if (object is RemoteInstance) {
      message = instanceStructureToString(object.instance, object.fields);
    } else {
      throw new UnimplementedError();
    }
    if (object.name != null) {
      // Prefix with name.
      message = "${object.name}: $message";
    }
    return message;
  }

  bool toggleInternal() {
    debugState.showInternalFrames = !debugState.showInternalFrames;
    if (debugState.currentBackTrace != null) {
      debugState.currentBackTrace.visibilityChanged();
    }
    return debugState.showInternalFrames;
  }

  bool toggleVerbose() {
    debugState.verbose = !debugState.verbose;
    return debugState.verbose;
  }

  // This method is a helper method for computing the default output for one
  // of the stop command results. There are currently the following stop
  // responses:
  //   ProcessTerminated
  //   ProcessBreakpoint
  //   UncaughtException
  //   ProcessCompileError
  //   ConnectionError
  Future<String> processStopResponseToString(
      VmCommand response,
      SessionState state) async {
    if (response is UncaughtException) {
      StringBuffer sb = new StringBuffer();
      // Print the exception first, followed by a stack trace.
      RemoteObject exception = await uncaughtException();
      sb.writeln(exceptionToString(exception));
      BackTrace trace = await backTrace();
      assert(trace != null);
      sb.write(trace.format());
      String result = '$sb';
      if (!result.endsWith('\n')) result = '$result\n';
      return result;

    } else if (response is ProcessBreakpoint) {
      // Print the current line of source code.
      BackTrace trace = await backTrace();
      assert(trace != null);
      BackTraceFrame topFrame = trace.visibleFrame(0);
      if (topFrame != null) {
        String result;
        if (debugState.verbose) {
          result = topFrame.list(state, contextLines: 0);
        } else {
          result = topFrame.shortString();
        }
        if (!result.endsWith('\n')) result = '$result\n';
        return result;
      }
    } else if (response is ProcessCompileTimeError) {
      // TODO(wibling): add information to ProcessCompileTimeError about the
      // specific error and print here.
      return '';
    } else if (response is ProcessTerminated) {
      return '### process terminated\n';

    } else if (response is ConnectionError) {
      return '### lost connection to the virtual machine\n';
    }
    return '';
  }
}
