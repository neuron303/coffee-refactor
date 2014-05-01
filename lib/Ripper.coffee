{ nodes } = require 'coffee-script'
{ Base, Value, Code, Block, Literal, For, Obj, Arr, Assign } = require '../node_modules/coffee-script/lib/coffee-script/nodes'
{ Range } = require 'atom'
{ inspect } = require 'util'
_ = require 'lodash'


LEVEL_TOP = 1
HEXNUM = /^[+-]?0x[\da-f]+/i
Value::isHexNumber = -> @bareLiteral(Literal) and HEXNUM.test @base.value


pad = (str, len, pad = ' ') ->
  while str.length < len
    str += pad
  str

padL = (str, len, pad = ' ') ->
  while str.length < len
    str = pad + str
  str


module.exports = class Parser

  @locationDataToRange: ({ first_line, first_column, last_line, last_column }) ->
    new Range [ first_line, first_column ], [ last_line, last_column + 1 ]

  @rangeToLocationData: ({ start, end }) ->
    first_line  : start.row
    first_column: start.column
    last_line   : end.row
    last_column : end.column - 1

  @isEqualLocationData: (a, b) ->
    return false unless a? and b?
    a.first_line   is b.first_line   and \
    a.first_column is b.first_column and \
    a.last_line    is b.last_line    and \
    a.last_column  is b.last_column

  @isContainsLocationData: (a, b) ->
    (
      a.first_line < b.first_line or \
      a.first_line is b.first_line and a.first_column <= b.first_column
    ) and \
    (
      b.last_line < a.last_line or \
      b.last_line is a.last_line and b.last_column <= a.last_column
    )

  @find: ({ symbol, references }, targetLocationData) ->
    target = @findSymbol symbol, targetLocationData
    return [] unless target?
    _.uniq @findReferences(references, target)[0]

  @findSymbol: (parent, targetLocationData) ->
    target = null

    parent.eachChild (child) ->
      # Skip if target is found
      return false if target?

      # Skip no locationData
      return true unless child.locationData?

      # Skip primitive node
      return true if child.isString?() or \
                     child.isSimpleNumber?() or \
                     child.isHexNumber?() or \
                     child.isRegex?()

      # Skip object key access
      if child.asKey
        return true

      # Skip key in object literal
      if child instanceof Value and \
         parent.context is 'object' and \
         parent instanceof Assign and \
         child is parent.variable
        return true

      if child instanceof For
        if child.name? and \
           Parser.isContainsLocationData child.name.locationData, targetLocationData
          target = child.name
          return false
        if child.index? and \
           Parser.isContainsLocationData child.index.locationData, targetLocationData
          target = child.index
          return false
      if child instanceof Literal
        if Parser.isContainsLocationData child.locationData, targetLocationData
          target = child
          return false

      target = Parser.findSymbol child, targetLocationData
      return false if target?

    target

  @findReferences: (parent, target, isDeclaredInParent) ->
    isDeclaredInParent ?= Parser.isDeclaredRoot parent, target
    isFixed = false
    dests = []

    parent.eachChild (child) ->
      if child instanceof Code
        isContains = Parser.isContains child, target
        isDeclared = Parser.isDeclared child, target
        console.log inspect { isDeclaredInParent, isDeclared, isContains }

        [ childDests, isChildFixed ] = Parser.findReferences child, target, isDeclaredInParent or isDeclared


        if isContains
          if isChildFixed
            dests = childDests
            isFixed = true
            return false
          if isDeclared
            dests = childDests
            isFixed = true
            return false
          dests = dests.concat childDests
        else
          if isDeclared
            return true
          if isDeclaredInParent
            dests = dests.concat childDests
            return true
        return true

      # Skip object key access
      if child.asKey and child.unfoldedSoak isnt false
        return true

      # Skip key in object literal
      if child instanceof Value and \
         parent.context is 'object' and \
         parent instanceof Assign and \
         child is parent.variable
        return true

      if child instanceof For
        if Parser.isSameLiteral child.name, target
          dests.push child.name
        if Parser.isSameLiteral child.index, target
          dests.push child.index
      if Parser.isSameLiteral child, target
        dests.push child
        return true

      [ childDests, isChildFixed ] = Parser.findReferences child, target, isDeclaredInParent
      if isChildFixed
        dests = childDests
        isFixed = true
        return false
      else
        dests = dests.concat childDests
        return true

    [ dests, isFixed ]

  @hasChild: (parent, child) ->
    for key, val of parent when parent.hasOwnProperty key
      return true if child is val
    false

  @isDeclaredRoot: (root, target) ->
    try
      #TODO cache declaredVariables
      if root.compiled?
        o = root.compiled
      else
        o = bare: true
        root.compileRoot o
        root.compiled = o
      variables = o.scope.declaredVariables()
      return variables.indexOf(target.value) isnt -1
    catch err
    false

  ###
  Check the target `Literal` is declared in the `Code`
  @param {Code} code A `Code`
  @param {Literal} target A `Literal`
  @returns {Boolean} Has declarations in the `Code`
  ###
  @isDeclared: (code, target) ->
    try
      #TODO cache declaredVariables
      if code.compiled?
        o = code.compiled
      else
        o =
          indent: ''
          bare: true
        code.compileNode o
        code.compiled = o
      variables = o.scope.declaredVariables()
      return variables.indexOf(target.value) isnt -1
    catch err
    false

  ###
  Check the target `Node` exsits in the `Node`.
  @param {Node} node A `Node`
  @param {Node} target The finding target `Node`.
  @returns {Boolean} Exists.
  ###
  @isContains: (node, target) ->
    isContains = false
    node.traverseChildren true, (child) ->
      if Parser.isEqualLocationData(child.locationData, target.locationData) and \
         Parser.isSameLiteral(child, target)
        isContains = true
        false
    isContains

  ###
  Check `Literal`s has same value
  @param {Literal} a A `Literal`
  @param {Literal} b Another `Literal`
  @returns {Boolean} Has same value
  ###
  @isSameLiteral: (a, b) ->
    a? and b? and \
    a.locationData? and b.locationData? and \
    a instanceof Literal and \
    b instanceof Literal and \
    a.value is b.value


  nodes: null

  destruct: ->
    delete @nodes

  parse: (code) ->
    try
      @nodes =
        symbol    : nodes code
        references: nodes code
    catch err
      delete @nodes

  find: (range) ->
    return [] unless @nodes?

    targetLocationData = Parser.rangeToLocationData range
    foundNodes = Parser.find @nodes, targetLocationData
    for { locationData }, i in foundNodes
      Parser.locationDataToRange locationData
