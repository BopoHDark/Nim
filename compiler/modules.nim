#
#
#           The Nim Compiler
#        (c) Copyright 2015 Andreas Rumpf
#
#    See the file "copying.txt", included in this
#    distribution, for details about the copyright.
#

## Implements the module handling, including the caching of modules.

import
  ast, astalgo, magicsys, std / sha1, msgs, cgendata, sigmatch, options,
  idents, os, lexer, idgen, passes, syntaxes, llstream, modulegraphs, rod,
  lineinfos

proc resetSystemArtifacts*(g: ModuleGraph) =
  magicsys.resetSysTypes(g)

proc newModule(graph: ModuleGraph; fileIdx: FileIndex): PSym =
  # We cannot call ``newSym`` here, because we have to circumvent the ID
  # mechanism, which we do in order to assign each module a persistent ID.
  new(result)
  result.id = -1             # for better error checking
  result.kind = skModule
  let filename = toFullPath(graph.config, fileIdx)
  result.name = getIdent(graph.cache, splitFile(filename).name)
  if not isNimIdentifier(result.name.s):
    rawMessage(graph.config, errGenerated, "invalid module name: " & result.name.s)

  result.info = newLineInfo(fileIdx, 1, 1)
  let
    pck = getPackageName(graph.config, filename)
    pck2 = if pck.len > 0: pck else: "unknown"
    pack = getIdent(graph.cache, pck2)
  var packSym = graph.packageSyms.strTableGet(pack)
  if packSym == nil:
    packSym = newSym(skPackage, getIdent(graph.cache, pck2), nil, result.info)
    initStrTable(packSym.tab)
    graph.packageSyms.strTableAdd(packSym)

  result.owner = packSym
  result.position = int fileIdx

  if int(fileIdx) >= graph.modules.len:
    setLen(graph.modules, int(fileIdx) + 1)
  #growCache graph.modules, int fileIdx
  graph.modules[result.position] = result

  incl(result.flags, sfUsed)
  initStrTable(result.tab)
  strTableAdd(result.tab, result) # a module knows itself
  let existing = strTableGet(packSym.tab, result.name)
  if existing != nil and existing.info.fileIndex != result.info.fileIndex:
    localError(graph.config, result.info,
      "module names need to be unique per Nimble package; module clashes with " &
        toFullPath(graph.config, existing.info.fileIndex))
  # strTableIncl() for error corrections:
  discard strTableIncl(packSym.tab, result)

proc compileModule*(graph: ModuleGraph; fileIdx: FileIndex; flags: TSymFlags): PSym =
  result = graph.getModule(fileIdx)
  if result == nil:
    result = newModule(graph, fileIdx)
    result.flags = result.flags + flags
    if sfMainModule in result.flags:
      graph.config.mainPackageId = result.owner.id

    result.id = getModuleId(graph, fileIdx, toFullPath(graph.config, fileIdx))
    discard processModule(graph, result,
      if sfMainModule in flags and graph.config.projectIsStdin: stdin.llStreamOpen else: nil)
  elif graph.isDirty(result):
    result.flags.excl sfDirty
    # reset module fields:
    initStrTable(result.tab)
    result.ast = nil
    discard processModule(graph, result,
      if sfMainModule in flags and graph.config.projectIsStdin: stdin.llStreamOpen else: nil)
    graph.markClientsDirty(fileIdx)

proc importModule*(graph: ModuleGraph; s: PSym, fileIdx: FileIndex): PSym {.procvar.} =
  # this is called by the semantic checking phase
  assert graph.config != nil
  result = compileModule(graph, fileIdx, {})
  graph.addDep(s, fileIdx)
  #if sfSystemModule in result.flags:
  #  localError(result.info, errAttemptToRedefine, result.name.s)
  # restore the notes for outer module:
  graph.config.notes =
    if s.owner.id == graph.config.mainPackageId: graph.config.mainPackageNotes
    else: graph.config.foreignPackageNotes

proc includeModule*(graph: ModuleGraph; s: PSym, fileIdx: FileIndex): PNode {.procvar.} =
  result = syntaxes.parseFile(fileIdx, graph.cache, graph.config)
  graph.addDep(s, fileIdx)
  graph.addIncludeDep(s.position.FileIndex, fileIdx)

proc connectCallbacks*(graph: ModuleGraph) =
  graph.includeFileCallback = includeModule
  graph.importModuleCallback = importModule

proc compileSystemModule*(graph: ModuleGraph) =
  if graph.systemModule == nil:
    connectCallbacks(graph)
    graph.config.m.systemFileIdx = fileInfoIdx(graph.config, graph.config.libpath / "system.nim")
    discard graph.compileModule(graph.config.m.systemFileIdx, {sfSystemModule})

proc wantMainModule*(conf: ConfigRef) =
  if conf.projectFull.len == 0:
    fatal(conf, newLineInfo(conf, "command line", 1, 1), errGenerated, "command expects a filename")
  conf.projectMainIdx = fileInfoIdx(conf, addFileExt(conf.projectFull, NimExt))

proc compileProject*(graph: ModuleGraph; projectFileIdx = InvalidFileIDX) =
  connectCallbacks(graph)
  let conf = graph.config
  wantMainModule(conf)
  let systemFileIdx = fileInfoIdx(conf, conf.libpath / "system.nim")
  let projectFile = if projectFileIdx == InvalidFileIDX: conf.projectMainIdx else: projectFileIdx
  graph.importStack.add projectFile
  if projectFile == systemFileIdx:
    discard graph.compileModule(projectFile, {sfMainModule, sfSystemModule})
  else:
    graph.compileSystemModule()
    discard graph.compileModule(projectFile, {sfMainModule})

proc makeModule*(graph: ModuleGraph; filename: string): PSym =
  result = graph.newModule(fileInfoIdx(graph.config, filename))
  result.id = getID()

proc makeStdinModule*(graph: ModuleGraph): PSym = graph.makeModule"stdin"
