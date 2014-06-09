_ = require 'underscore-plus'
{Emitter} = require 'emissary'
guid = require 'guid'
Serializable = require 'serializable'
{Model} = require 'theorist'
{Point, Range} = require 'text-buffer'
TokenizedBuffer = require './tokenized-buffer'
RowMap = require './row-map'
Fold = require './fold'
Token = require './token'
DisplayBufferMarker = require './display-buffer-marker'

class BufferToScreenConversionError extends Error
  constructor: (@message, @metadata) ->
    super
    Error.captureStackTrace(this, BufferToScreenConversionError)

module.exports =
class DisplayBuffer extends Model
  Serializable.includeInto(this)

  @properties
    manageScrollPosition: false
    softWrap: null
    editorWidthInChars: null
    lineHeightInPixels: null
    defaultCharWidth: null
    height: null
    width: null
    scrollTop: 0
    scrollLeft: 0

  verticalScrollMargin: 2
  horizontalScrollMargin: 6
  horizontalScrollbarHeight: 15
  verticalScrollbarWidth: 15

  constructor: ({tabLength, @editorWidthInChars, @tokenizedBuffer, buffer}={}) ->
    super
    @softWrap ?= atom.config.get('editor.softWrap') ? false
    @tokenizedBuffer ?= new TokenizedBuffer({tabLength, buffer})
    @buffer = @tokenizedBuffer.buffer
    @charWidthsByScope = {}
    @markers = {}
    @foldsByMarkerId = {}
    @decorations = {}
    @decorationMarkerSubscriptions = {}
    @updateAllScreenLines()
    @createFoldForMarker(marker) for marker in @buffer.findMarkers(@getFoldMarkerAttributes())
    @subscribe @tokenizedBuffer, 'grammar-changed', (grammar) => @emit 'grammar-changed', grammar
    @subscribe @tokenizedBuffer, 'tokenized', => @emit 'tokenized'
    @subscribe @tokenizedBuffer, 'changed', @handleTokenizedBufferChange
    @subscribe @buffer, 'markers-updated', @handleBufferMarkersUpdated
    @subscribe @buffer, 'marker-created', @handleBufferMarkerCreated

    @subscribe @$softWrap, (softWrap) =>
      @emit 'soft-wrap-changed', softWrap
      @updateWrappedScreenLines()

    @subscribe atom.config.observe 'editor.preferredLineLength', callNow: false, =>
      @updateWrappedScreenLines() if @softWrap and atom.config.get('editor.softWrapAtPreferredLineLength')

    @subscribe atom.config.observe 'editor.softWrapAtPreferredLineLength', callNow: false, =>
      @updateWrappedScreenLines() if @softWrap

  serializeParams: ->
    id: @id
    softWrap: @softWrap
    editorWidthInChars: @editorWidthInChars
    scrollTop: @scrollTop
    scrollLeft: @scrollLeft
    tokenizedBuffer: @tokenizedBuffer.serialize()

  deserializeParams: (params) ->
    params.tokenizedBuffer = TokenizedBuffer.deserialize(params.tokenizedBuffer)
    params

  copy: ->
    newDisplayBuffer = new DisplayBuffer({@buffer, tabLength: @getTabLength()})
    newDisplayBuffer.setScrollTop(@getScrollTop())
    newDisplayBuffer.setScrollLeft(@getScrollLeft())

    for marker in @findMarkers(displayBufferId: @id)
      marker.copy(displayBufferId: newDisplayBuffer.id)
    newDisplayBuffer

  updateAllScreenLines: ->
    @maxLineLength = 0
    @screenLines = []
    @rowMap = new RowMap
    @updateScreenLines(0, @buffer.getLineCount(), null, suppressChangeEvent: true)

  emitChanged: (eventProperties, refreshMarkers=true) ->
    if refreshMarkers
      @pauseMarkerObservers()
      @refreshMarkerScreenPositions()
    @emit 'changed', eventProperties
    @resumeMarkerObservers()

  updateWrappedScreenLines: ->
    start = 0
    end = @getLastRow()
    @updateAllScreenLines()
    screenDelta = @getLastRow() - end
    bufferDelta = 0
    @emitChanged({ start, end, screenDelta, bufferDelta })

  # Sets the visibility of the tokenized buffer.
  #
  # visible - A {Boolean} indicating of the tokenized buffer is shown
  setVisible: (visible) -> @tokenizedBuffer.setVisible(visible)

  getVerticalScrollMargin: -> @verticalScrollMargin
  setVerticalScrollMargin: (@verticalScrollMargin) -> @verticalScrollMargin

  getHorizontalScrollMargin: -> @horizontalScrollMargin
  setHorizontalScrollMargin: (@horizontalScrollMargin) -> @horizontalScrollMargin

  getHorizontalScrollbarHeight: -> @horizontalScrollbarHeight
  setHorizontalScrollbarHeight: (@horizontalScrollbarHeight) -> @horizontalScrollbarHeight

  getVerticalScrollbarWidth: -> @verticalScrollbarWidth
  setVerticalScrollbarWidth: (@verticalScrollbarWidth) -> @verticalScrollbarWidth

  getHeight: ->
    if @height?
      @height
    else
      if @horizontallyScrollable()
        @getScrollHeight() + @getHorizontalScrollbarHeight()
      else
        @getScrollHeight()

  setHeight: (@height) -> @height

  getClientHeight: (reentrant) ->
    if @horizontallyScrollable(reentrant)
      @getHeight() - @getHorizontalScrollbarHeight()
    else
      @getHeight()

  getClientWidth: (reentrant) ->
    if @verticallyScrollable(reentrant)
      @getWidth() - @getVerticalScrollbarWidth()
    else
      @getWidth()

  horizontallyScrollable: (reentrant) ->
    return false unless @width?
    return false if @getSoftWrap()
    if reentrant
      @getScrollWidth() > @getWidth()
    else
      @getScrollWidth() > @getClientWidth(true)

  verticallyScrollable: (reentrant) ->
    return false unless @height?
    if reentrant
      @getScrollHeight() > @getHeight()
    else
      @getScrollHeight() > @getClientHeight(true)

  getWidth: ->
    if @width?
      @width
    else
      if @verticallyScrollable()
        @getScrollWidth() + @getVerticalScrollbarWidth()
      else
        @getScrollWidth()

  setWidth: (newWidth) ->
    oldWidth = @width
    @width = newWidth
    @updateWrappedScreenLines() if newWidth isnt oldWidth and @softWrap
    @setScrollTop(@getScrollTop()) # Ensure scrollTop is still valid in case horizontal scrollbar disappeared
    @width

  getScrollTop: -> @scrollTop
  setScrollTop: (scrollTop) ->
    if @manageScrollPosition
      @scrollTop = Math.max(0, Math.min(@getScrollHeight() - @getClientHeight(), scrollTop))
    else
      @scrollTop = scrollTop

  getScrollBottom: -> @scrollTop + @height
  setScrollBottom: (scrollBottom) ->
    @setScrollTop(scrollBottom - @getClientHeight())
    @getScrollBottom()

  getScrollLeft: -> @scrollLeft
  setScrollLeft: (scrollLeft) ->
    if @manageScrollPosition
      @scrollLeft = Math.max(0, Math.min(@getScrollWidth() - @getClientWidth(), scrollLeft))
      @scrollLeft
    else
      @scrollLeft = scrollLeft

  getScrollRight: -> @scrollLeft + @width
  setScrollRight: (scrollRight) ->
    @setScrollLeft(scrollRight - @width)
    @getScrollRight()

  getLineHeightInPixels: -> @lineHeightInPixels
  setLineHeightInPixels: (@lineHeightInPixels) -> @lineHeightInPixels

  getDefaultCharWidth: -> @defaultCharWidth
  setDefaultCharWidth: (@defaultCharWidth) -> @defaultCharWidth

  getCursorWidth: -> 1

  getScopedCharWidth: (scopeNames, char) ->
    @getScopedCharWidths(scopeNames)[char]

  getScopedCharWidths: (scopeNames) ->
    scope = @charWidthsByScope
    for scopeName in scopeNames
      scope[scopeName] ?= {}
      scope = scope[scopeName]
    scope.charWidths ?= {}
    scope.charWidths

  setScopedCharWidth: (scopeNames, char, width) ->
    @getScopedCharWidths(scopeNames)[char] = width

  setScopedCharWidths: (scopeNames, charWidths) ->
    _.extend(@getScopedCharWidths(scopeNames), charWidths)

  clearScopedCharWidths: ->
    @charWidthsByScope = {}

  getScrollHeight: ->
    unless @getLineHeightInPixels() > 0
      throw new Error("You must assign lineHeightInPixels before calling ::getScrollHeight()")

    @getLineCount() * @getLineHeightInPixels()

  getScrollWidth: ->
    (@getMaxLineLength() * @getDefaultCharWidth()) + @getCursorWidth()

  getVisibleRowRange: ->
    unless @getLineHeightInPixels() > 0
      throw new Error("You must assign a non-zero lineHeightInPixels before calling ::getVisibleRowRange()")

    heightInLines = Math.ceil(@getHeight() / @getLineHeightInPixels()) + 1
    startRow = Math.floor(@getScrollTop() / @getLineHeightInPixels())
    endRow = Math.min(@getLineCount(), startRow + heightInLines)

    [startRow, endRow]

  intersectsVisibleRowRange: (startRow, endRow) ->
    [visibleStart, visibleEnd] = @getVisibleRowRange()
    not (endRow <= visibleStart or visibleEnd <= startRow)

  selectionIntersectsVisibleRowRange: (selection) ->
    {start, end} = selection.getScreenRange()
    @intersectsVisibleRowRange(start.row, end.row + 1)

  scrollToScreenRange: (screenRange) ->
    verticalScrollMarginInPixels = @getVerticalScrollMargin() * @getLineHeightInPixels()
    horizontalScrollMarginInPixels = @getHorizontalScrollMargin() * @getDefaultCharWidth()

    {top, left, height, width} = @pixelRectForScreenRange(screenRange)
    bottom = top + height
    right = left + width
    desiredScrollTop = top - verticalScrollMarginInPixels
    desiredScrollBottom = bottom + verticalScrollMarginInPixels
    desiredScrollLeft = left - horizontalScrollMarginInPixels
    desiredScrollRight = right + horizontalScrollMarginInPixels

    if desiredScrollTop < @getScrollTop()
      @setScrollTop(desiredScrollTop)
    else if desiredScrollBottom > @getScrollBottom()
      @setScrollBottom(desiredScrollBottom)

    if desiredScrollLeft < @getScrollLeft()
      @setScrollLeft(desiredScrollLeft)
    else if desiredScrollRight > @getScrollRight()
      @setScrollRight(desiredScrollRight)

  scrollToScreenPosition: (screenPosition) ->
    @scrollToScreenRange(new Range(screenPosition, screenPosition))

  scrollToBufferPosition: (bufferPosition) ->
    @scrollToScreenPosition(@screenPositionForBufferPosition(bufferPosition))

  pixelRectForScreenRange: (screenRange) ->
    if screenRange.end.row > screenRange.start.row
      top = @pixelPositionForScreenPosition(screenRange.start).top
      left = 0
      height = (screenRange.end.row - screenRange.start.row + 1) * @getLineHeightInPixels()
      width = @getScrollWidth()
    else
      {top, left} = @pixelPositionForScreenPosition(screenRange.start)
      height = @getLineHeightInPixels()
      width = @pixelPositionForScreenPosition(screenRange.end).left - left

    {top, left, width, height}

  # Retrieves the current tab length.
  #
  # Returns a {Number}.
  getTabLength: ->
    @tokenizedBuffer.getTabLength()

  # Specifies the tab length.
  #
  # tabLength - A {Number} that defines the new tab length.
  setTabLength: (tabLength) ->
    @tokenizedBuffer.setTabLength(tabLength)

  # Deprecated: Use the softWrap property directly
  setSoftWrap: (@softWrap) -> @softWrap

  # Deprecated: Use the softWrap property directly
  getSoftWrap: -> @softWrap

  # Set the number of characters that fit horizontally in the editor.
  #
  # editorWidthInChars - A {Number} of characters.
  setEditorWidthInChars: (editorWidthInChars) ->
    if editorWidthInChars > 0
      previousWidthInChars = @editorWidthInChars
      @editorWidthInChars = editorWidthInChars
      if editorWidthInChars isnt previousWidthInChars and @softWrap
        @updateWrappedScreenLines()

  getEditorWidthInChars: ->
    width = @getWidth()
    if width? and @defaultCharWidth > 0
      Math.floor(width / @defaultCharWidth)
    else
      @editorWidthInChars

  getSoftWrapColumn: ->
    if atom.config.get('editor.softWrapAtPreferredLineLength')
      Math.min(@getEditorWidthInChars(), atom.config.getPositiveInt('editor.preferredLineLength', @getEditorWidthInChars()))
    else
      @getEditorWidthInChars()

  # Gets the screen line for the given screen row.
  #
  # screenRow - A {Number} indicating the screen row.
  #
  # Returns a {ScreenLine}.
  lineForRow: (row) ->
    @screenLines[row]

  # Gets the screen lines for the given screen row range.
  #
  # startRow - A {Number} indicating the beginning screen row.
  # endRow - A {Number} indicating the ending screen row.
  #
  # Returns an {Array} of {ScreenLine}s.
  linesForRows: (startRow, endRow) ->
    @screenLines[startRow..endRow]

  # Gets all the screen lines.
  #
  # Returns an {Array} of {ScreenLines}s.
  getLines: ->
    new Array(@screenLines...)

  indentLevelForLine: (line) ->
    @tokenizedBuffer.indentLevelForLine(line)

  # Given starting and ending screen rows, this returns an array of the
  # buffer rows corresponding to every screen row in the range
  #
  # startScreenRow - The screen row {Number} to start at
  # endScreenRow - The screen row {Number} to end at (default: the last screen row)
  #
  # Returns an {Array} of buffer rows as {Numbers}s.
  bufferRowsForScreenRows: (startScreenRow, endScreenRow) ->
    for screenRow in [startScreenRow..endScreenRow]
      @rowMap.bufferRowRangeForScreenRow(screenRow)[0]

  # Creates a new fold between two row numbers.
  #
  # startRow - The row {Number} to start folding at
  # endRow - The row {Number} to end the fold
  #
  # Returns the new {Fold}.
  createFold: (startRow, endRow) ->
    foldMarker =
      @findFoldMarker({startRow, endRow}) ?
        @buffer.markRange([[startRow, 0], [endRow, Infinity]], @getFoldMarkerAttributes())
    @foldForMarker(foldMarker)

  isFoldedAtBufferRow: (bufferRow) ->
    @largestFoldContainingBufferRow(bufferRow)?

  isFoldedAtScreenRow: (screenRow) ->
    @largestFoldContainingBufferRow(@bufferRowForScreenRow(screenRow))?

  # Destroys the fold with the given id
  destroyFoldWithId: (id) ->
    @foldsByMarkerId[id]?.destroy()

  # Removes any folds found that contain the given buffer row.
  #
  # bufferRow - The buffer row {Number} to check against
  unfoldBufferRow: (bufferRow) ->
    fold.destroy() for fold in @foldsContainingBufferRow(bufferRow)

  # Given a buffer row, this returns the largest fold that starts there.
  #
  # Largest is defined as the fold whose difference between its start and end points
  # are the greatest.
  #
  # bufferRow - A {Number} indicating the buffer row
  #
  # Returns a {Fold} or null if none exists.
  largestFoldStartingAtBufferRow: (bufferRow) ->
    @foldsStartingAtBufferRow(bufferRow)[0]

  # Public: Given a buffer row, this returns all folds that start there.
  #
  # bufferRow - A {Number} indicating the buffer row
  #
  # Returns an {Array} of {Fold}s.
  foldsStartingAtBufferRow: (bufferRow) ->
    for marker in @findFoldMarkers(startRow: bufferRow)
      @foldForMarker(marker)

  # Given a screen row, this returns the largest fold that starts there.
  #
  # Largest is defined as the fold whose difference between its start and end points
  # are the greatest.
  #
  # screenRow - A {Number} indicating the screen row
  #
  # Returns a {Fold}.
  largestFoldStartingAtScreenRow: (screenRow) ->
    @largestFoldStartingAtBufferRow(@bufferRowForScreenRow(screenRow))

  # Given a buffer row, this returns the largest fold that includes it.
  #
  # Largest is defined as the fold whose difference between its start and end rows
  # is the greatest.
  #
  # bufferRow - A {Number} indicating the buffer row
  #
  # Returns a {Fold}.
  largestFoldContainingBufferRow: (bufferRow) ->
    @foldsContainingBufferRow(bufferRow)[0]

  # Returns the folds in the given row range (exclusive of end row) that are
  # not contained by any other folds.
  outermostFoldsInBufferRowRange: (startRow, endRow) ->
    @findFoldMarkers(containedInRange: [[startRow, 0], [endRow, 0]])
      .map (marker) => @foldForMarker(marker)
      .filter (fold) -> not fold.isInsideLargerFold()

  # Public: Given a buffer row, this returns folds that include it.
  #
  #
  # bufferRow - A {Number} indicating the buffer row
  #
  # Returns an {Array} of {Fold}s.
  foldsContainingBufferRow: (bufferRow) ->
    for marker in @findFoldMarkers(intersectsRow: bufferRow)
      @foldForMarker(marker)

  # Given a buffer row, this converts it into a screen row.
  #
  # bufferRow - A {Number} representing a buffer row
  #
  # Returns a {Number}.
  screenRowForBufferRow: (bufferRow) ->
    @rowMap.screenRowRangeForBufferRow(bufferRow)[0]

  lastScreenRowForBufferRow: (bufferRow) ->
    @rowMap.screenRowRangeForBufferRow(bufferRow)[1] - 1

  # Given a screen row, this converts it into a buffer row.
  #
  # screenRow - A {Number} representing a screen row
  #
  # Returns a {Number}.
  bufferRowForScreenRow: (screenRow) ->
    @rowMap.bufferRowRangeForScreenRow(screenRow)[0]

  # Given a buffer range, this converts it into a screen position.
  #
  # bufferRange - The {Range} to convert
  #
  # Returns a {Range}.
  screenRangeForBufferRange: (bufferRange) ->
    bufferRange = Range.fromObject(bufferRange)
    start = @screenPositionForBufferPosition(bufferRange.start)
    end = @screenPositionForBufferPosition(bufferRange.end)
    new Range(start, end)

  # Given a screen range, this converts it into a buffer position.
  #
  # screenRange - The {Range} to convert
  #
  # Returns a {Range}.
  bufferRangeForScreenRange: (screenRange) ->
    screenRange = Range.fromObject(screenRange)
    start = @bufferPositionForScreenPosition(screenRange.start)
    end = @bufferPositionForScreenPosition(screenRange.end)
    new Range(start, end)

  pixelRangeForScreenRange: (screenRange, clip=true) ->
    {start, end} = Range.fromObject(screenRange)
    {start: @pixelPositionForScreenPosition(start, clip), end: @pixelPositionForScreenPosition(end, clip)}

  pixelPositionForScreenPosition: (screenPosition, clip=true) ->
    screenPosition = Point.fromObject(screenPosition)
    screenPosition = @clipScreenPosition(screenPosition) if clip

    targetRow = screenPosition.row
    targetColumn = screenPosition.column
    defaultCharWidth = @defaultCharWidth

    top = targetRow * @lineHeightInPixels
    left = 0
    column = 0
    for token in @lineForRow(targetRow).tokens
      charWidths = @getScopedCharWidths(token.scopes)
      for char in token.value
        return {top, left} if column is targetColumn
        left += charWidths[char] ? defaultCharWidth
        column++
    {top, left}

  screenPositionForPixelPosition: (pixelPosition) ->
    targetTop = pixelPosition.top
    targetLeft = pixelPosition.left
    defaultCharWidth = @defaultCharWidth
    row = Math.floor(targetTop / @getLineHeightInPixels())
    row = Math.min(row, @getLastRow())
    row = Math.max(0, row)

    left = 0
    column = 0
    for token in @lineForRow(row).tokens
      charWidths = @getScopedCharWidths(token.scopes)
      for char in token.value
        charWidth = charWidths[char] ? defaultCharWidth
        break if targetLeft <= left + (charWidth / 2)
        left += charWidth
        column++

    new Point(row, column)

  pixelPositionForBufferPosition: (bufferPosition) ->
    @pixelPositionForScreenPosition(@screenPositionForBufferPosition(bufferPosition))

  # Gets the number of screen lines.
  #
  # Returns a {Number}.
  getLineCount: ->
    @screenLines.length

  # Gets the number of the last screen line.
  #
  # Returns a {Number}.
  getLastRow: ->
    @getLineCount() - 1

  # Gets the length of the longest screen line.
  #
  # Returns a {Number}.
  getMaxLineLength: ->
    @maxLineLength

  # Given a buffer position, this converts it into a screen position.
  #
  # bufferPosition - An object that represents a buffer position. It can be either
  #                  an {Object} (`{row, column}`), {Array} (`[row, column]`), or {Point}
  # options - A hash of options with the following keys:
  #           wrapBeyondNewlines:
  #           wrapAtSoftNewlines:
  #
  # Returns a {Point}.
  screenPositionForBufferPosition: (bufferPosition, options) ->
    { row, column } = @buffer.clipPosition(bufferPosition)
    [startScreenRow, endScreenRow] = @rowMap.screenRowRangeForBufferRow(row)
    for screenRow in [startScreenRow...endScreenRow]
      screenLine = @screenLines[screenRow]

      unless screenLine?
        throw new BufferToScreenConversionError "No screen line exists when converting buffer row to screen row",
          softWrapEnabled: @getSoftWrap()
          foldCount: @findFoldMarkers().length
          lastBufferRow: @buffer.getLastRow()
          lastScreenRow: @getLastRow()

      maxBufferColumn = screenLine.getMaxBufferColumn()
      if screenLine.isSoftWrapped() and column > maxBufferColumn
        continue
      else
        if column <= maxBufferColumn
          screenColumn = screenLine.screenColumnForBufferColumn(column)
        else
          screenColumn = Infinity
        break

    @clipScreenPosition([screenRow, screenColumn], options)

  # Given a buffer position, this converts it into a screen position.
  #
  # screenPosition - An object that represents a buffer position. It can be either
  #                  an {Object} (`{row, column}`), {Array} (`[row, column]`), or {Point}
  # options - A hash of options with the following keys:
  #           wrapBeyondNewlines:
  #           wrapAtSoftNewlines:
  #
  # Returns a {Point}.
  bufferPositionForScreenPosition: (screenPosition, options) ->
    { row, column } = @clipScreenPosition(Point.fromObject(screenPosition), options)
    [bufferRow] = @rowMap.bufferRowRangeForScreenRow(row)
    new Point(bufferRow, @screenLines[row].bufferColumnForScreenColumn(column))

  # Retrieves the grammar's token scopes for a buffer position.
  #
  # bufferPosition - A {Point} in the {TextBuffer}
  #
  # Returns an {Array} of {String}s.
  scopesForBufferPosition: (bufferPosition) ->
    @tokenizedBuffer.scopesForPosition(bufferPosition)

  bufferRangeForScopeAtPosition: (selector, position) ->
    @tokenizedBuffer.bufferRangeForScopeAtPosition(selector, position)

  # Retrieves the grammar's token for a buffer position.
  #
  # bufferPosition - A {Point} in the {TextBuffer}.
  #
  # Returns a {Token}.
  tokenForBufferPosition: (bufferPosition) ->
    @tokenizedBuffer.tokenForPosition(bufferPosition)

  # Get the grammar for this buffer.
  #
  # Returns the current {Grammar} or the {NullGrammar}.
  getGrammar: ->
    @tokenizedBuffer.grammar

  # Sets the grammar for the buffer.
  #
  # grammar - Sets the new grammar rules
  setGrammar: (grammar) ->
    @tokenizedBuffer.setGrammar(grammar)

  # Reloads the current grammar.
  reloadGrammar: ->
    @tokenizedBuffer.reloadGrammar()

  # Given a position, this clips it to a real position.
  #
  # For example, if `position`'s row exceeds the row count of the buffer,
  # or if its column goes beyond a line's length, this "sanitizes" the value
  # to a real position.
  #
  # position - The {Point} to clip
  # options - A hash with the following values:
  #           wrapBeyondNewlines: if `true`, continues wrapping past newlines
  #           wrapAtSoftNewlines: if `true`, continues wrapping past soft newlines
  #           screenLine: if `true`, indicates that you're using a line number, not a row number
  #
  # Returns the new, clipped {Point}. Note that this could be the same as `position` if no clipping was performed.
  clipScreenPosition: (screenPosition, options={}) ->
    { wrapBeyondNewlines, wrapAtSoftNewlines } = options
    { row, column } = Point.fromObject(screenPosition)

    if row < 0
      row = 0
      column = 0
    else if row > @getLastRow()
      row = @getLastRow()
      column = Infinity
    else if column < 0
      column = 0

    screenLine = @screenLines[row]
    maxScreenColumn = screenLine.getMaxScreenColumn()

    if screenLine.isSoftWrapped() and column >= maxScreenColumn
      if wrapAtSoftNewlines
        row++
        column = 0
      else
        column = screenLine.clipScreenColumn(maxScreenColumn - 1)
    else if wrapBeyondNewlines and column > maxScreenColumn and row < @getLastRow()
      row++
      column = 0
    else
      column = screenLine.clipScreenColumn(column, options)
    new Point(row, column)

  # Given a line, finds the point where it would wrap.
  #
  # line - The {String} to check
  # softWrapColumn - The {Number} where you want soft wrapping to occur
  #
  # Returns a {Number} representing the `line` position where the wrap would take place.
  # Returns `null` if a wrap wouldn't occur.
  findWrapColumn: (line, softWrapColumn=@getSoftWrapColumn()) ->
    return unless @softWrap
    return unless line.length > softWrapColumn

    if /\s/.test(line[softWrapColumn])
      # search forward for the start of a word past the boundary
      for column in [softWrapColumn..line.length]
        return column if /\S/.test(line[column])
      return line.length
    else
      # search backward for the start of the word on the boundary
      for column in [softWrapColumn..0]
        return column + 1 if /\s/.test(line[column])
      return softWrapColumn

  # Calculates a {Range} representing the start of the {TextBuffer} until the end.
  #
  # Returns a {Range}.
  rangeForAllLines: ->
    new Range([0, 0], @clipScreenPosition([Infinity, Infinity]))

  decorationsForBufferRow: (bufferRow, decorationType) ->
    decorations = @decorations[bufferRow] ? []
    decorations = (dec for dec in decorations when not dec.type? or dec.type is decorationType) if decorationType?
    decorations

  decorationsForBufferRowRange: (startBufferRow, endBufferRow, decorationType) ->
    decorations = {}
    for bufferRow in [startBufferRow..endBufferRow]
      decorations[bufferRow] = @decorationsForBufferRow(bufferRow, decorationType)
    decorations

  addDecorationToBufferRow: (bufferRow, decoration) ->
    @decorations[bufferRow] ?= []
    for current in @decorations[bufferRow]
      return if _.isEqual(current, decoration)
    @decorations[bufferRow].push(decoration)
    @emit 'decoration-changed', {bufferRow, decoration, action: 'add'}

  removeDecorationFromBufferRow: (bufferRow, decorationPattern) ->
    return unless decorations = @decorations[bufferRow]

    removed = []
    i = decorations.length - 1
    while i >= 0
      if @decorationMatchesPattern(decorations[i], decorationPattern)
        removed.push decorations[i]
        decorations.splice(i, 1)
      i--

    delete @decorations[bufferRow] unless @decorations[bufferRow]?

    for decoration in removed
      @emit 'decoration-changed', {bufferRow, decoration, action: 'remove'}

    removed

  addDecorationToBufferRowRange: (startBufferRow, endBufferRow, decoration) ->
    for bufferRow in [startBufferRow..endBufferRow]
      @addDecorationToBufferRow(bufferRow, decoration)
    return

  removeDecorationFromBufferRowRange: (startBufferRow, endBufferRow, decoration) ->
    for bufferRow in [startBufferRow..endBufferRow]
      @removeDecorationFromBufferRow(bufferRow, decoration)
    return

  decorationMatchesPattern: (decoration, decorationPattern) ->
    return false unless decoration? and decorationPattern?
    for key, value of decorationPattern
      return false if decoration[key] != value
    true

  addDecorationForMarker: (marker, decoration) ->
    startRow = marker.getStartBufferPosition().row
    endRow = marker.getEndBufferPosition().row
    @addDecorationToBufferRowRange(startRow, endRow, decoration)

    changedSubscription = @subscribe marker, 'changed', (e) =>
      oldStartRow = e.oldHeadBufferPosition.row
      oldEndRow = e.oldTailBufferPosition.row
      newStartRow = e.newHeadBufferPosition.row
      newEndRow = e.newTailBufferPosition.row

      # swap so head is always <= than tail
      [oldEndRow, oldStartRow] = [oldStartRow, oldEndRow] if oldStartRow > oldEndRow
      [newEndRow, newStartRow] = [newStartRow, newEndRow] if newStartRow > newEndRow

      @removeDecorationFromBufferRowRange(oldStartRow, oldEndRow, decoration)
      @addDecorationToBufferRowRange(newStartRow, newEndRow, decoration) if e.isValid

    destroyedSubscription = @subscribe marker, 'destroyed', (e) =>
      @removeDecorationForMarker(marker, decoration)

    @decorationMarkerSubscriptions[marker.id] ?= []
    @decorationMarkerSubscriptions[marker.id].push {decoration, changedSubscription, destroyedSubscription}

  removeDecorationForMarker: (marker, decorationPattern) ->
    return unless @decorationMarkerSubscriptions[marker.id]?

    startRow = marker.getStartBufferPosition().row
    endRow = marker.getEndBufferPosition().row
    @removeDecorationFromBufferRowRange(startRow, endRow, decorationPattern)

    for subscription in _.clone(@decorationMarkerSubscriptions[marker.id])
      if @decorationMatchesPattern(subscription.decoration, decorationPattern)
        subscription.changedSubscription.off()
        subscription.destroyedSubscription.off()
        @decorationMarkerSubscriptions[marker.id] = _.without(@decorationMarkerSubscriptions[marker.id], subscription)

    return

  # Retrieves a {DisplayBufferMarker} based on its id.
  #
  # id - A {Number} representing a marker id
  #
  # Returns the {DisplayBufferMarker} (if it exists).
  getMarker: (id) ->
    unless marker = @markers[id]
      if bufferMarker = @buffer.getMarker(id)
        marker = new DisplayBufferMarker({bufferMarker, displayBuffer: this})
        @markers[id] = marker
    marker

  # Retrieves the active markers in the buffer.
  #
  # Returns an {Array} of existing {DisplayBufferMarker}s.
  getMarkers: ->
    @buffer.getMarkers().map ({id}) => @getMarker(id)

  getMarkerCount: ->
    @buffer.getMarkerCount()

  # Public: Constructs a new marker at the given screen range.
  #
  # range - The marker {Range} (representing the distance between the head and tail)
  # options - Options to pass to the {Marker} constructor
  #
  # Returns a {Number} representing the new marker's ID.
  markScreenRange: (args...) ->
    bufferRange = @bufferRangeForScreenRange(args.shift())
    @markBufferRange(bufferRange, args...)

  # Public: Constructs a new marker at the given buffer range.
  #
  # range - The marker {Range} (representing the distance between the head and tail)
  # options - Options to pass to the {Marker} constructor
  #
  # Returns a {Number} representing the new marker's ID.
  markBufferRange: (range, options) ->
    @getMarker(@buffer.markRange(range, options).id)

  # Public: Constructs a new marker at the given screen position.
  #
  # range - The marker {Range} (representing the distance between the head and tail)
  # options - Options to pass to the {Marker} constructor
  #
  # Returns a {Number} representing the new marker's ID.
  markScreenPosition: (screenPosition, options) ->
    @markBufferPosition(@bufferPositionForScreenPosition(screenPosition), options)

  # Public: Constructs a new marker at the given buffer position.
  #
  # range - The marker {Range} (representing the distance between the head and tail)
  # options - Options to pass to the {Marker} constructor
  #
  # Returns a {Number} representing the new marker's ID.
  markBufferPosition: (bufferPosition, options) ->
    @getMarker(@buffer.markPosition(bufferPosition, options).id)

  # Public: Removes the marker with the given id.
  #
  # id - The {Number} of the ID to remove
  destroyMarker: (id) ->
    @buffer.destroyMarker(id)
    delete @markers[id]

  # Finds the first marker satisfying the given attributes
  #
  # Refer to {DisplayBuffer::findMarkers} for details.
  #
  # Returns a {DisplayBufferMarker} or null
  findMarker: (params) ->
    @findMarkers(params)[0]

  # Public: Find all markers satisfying a set of parameters.
  #
  # params - An {Object} containing parameters that all returned markers must
  #   satisfy. Unreserved keys will be compared against the markers' custom
  #   properties. There are also the following reserved keys with special
  #   meaning for the query:
  #   :startBufferRow - A {Number}. Only returns markers starting at this row in
  #     buffer coordinates.
  #   :endBufferRow - A {Number}. Only returns markers ending at this row in
  #     buffer coordinates.
  #   :containsBufferRange - A {Range} or range-compatible {Array}. Only returns
  #     markers containing this range in buffer coordinates.
  #   :containsBufferPosition - A {Point} or point-compatible {Array}. Only
  #     returns markers containing this position in buffer coordinates.
  #   :containedInBufferRange - A {Range} or range-compatible {Array}. Only
  #     returns markers contained within this range.
  #
  # Returns an {Array} of {DisplayBufferMarker}s
  findMarkers: (params) ->
    params = @translateToBufferMarkerParams(params)
    @buffer.findMarkers(params).map (stringMarker) => @getMarker(stringMarker.id)

  translateToBufferMarkerParams: (params) ->
    bufferMarkerParams = {}
    for key, value of params
      switch key
        when 'startBufferRow'
          key = 'startRow'
        when 'endBufferRow'
          key = 'endRow'
        when 'containsBufferRange'
          key = 'containsRange'
        when 'containsBufferPosition'
          key = 'containsPosition'
        when 'containedInBufferRange'
          key = 'containedInRange'
      bufferMarkerParams[key] = value
    bufferMarkerParams

  findFoldMarker: (attributes) ->
    @findFoldMarkers(attributes)[0]

  findFoldMarkers: (attributes) ->
    @buffer.findMarkers(@getFoldMarkerAttributes(attributes))

  getFoldMarkerAttributes: (attributes={}) ->
    _.extend(attributes, class: 'fold', displayBufferId: @id)

  pauseMarkerObservers: ->
    marker.pauseEvents() for marker in @getMarkers()

  resumeMarkerObservers: ->
    marker.resumeEvents() for marker in @getMarkers()
    @emit 'markers-updated'

  refreshMarkerScreenPositions: ->
    for marker in @getMarkers()
      marker.notifyObservers(textChanged: false)

  destroy: ->
    marker.unsubscribe() for marker in @getMarkers()
    @tokenizedBuffer.destroy()
    @unsubscribe()

  logLines: (start=0, end=@getLastRow())->
    for row in [start..end]
      line = @lineForRow(row).text
      console.log row, @bufferRowForScreenRow(row), line, line.length

  handleTokenizedBufferChange: (tokenizedBufferChange) =>
    {start, end, delta, bufferChange} = tokenizedBufferChange
    @updateScreenLines(start, end + 1, delta, delayChangeEvent: bufferChange?)

  updateScreenLines: (startBufferRow, endBufferRow, bufferDelta=0, options={}) ->
    startBufferRow = @rowMap.bufferRowRangeForBufferRow(startBufferRow)[0]
    endBufferRow = @rowMap.bufferRowRangeForBufferRow(endBufferRow - 1)[1]
    startScreenRow = @rowMap.screenRowRangeForBufferRow(startBufferRow)[0]
    endScreenRow = @rowMap.screenRowRangeForBufferRow(endBufferRow - 1)[1]

    {screenLines, regions} = @buildScreenLines(startBufferRow, endBufferRow + bufferDelta)
    @screenLines[startScreenRow...endScreenRow] = screenLines
    @rowMap.spliceRegions(startBufferRow, endBufferRow - startBufferRow, regions)
    @findMaxLineLength(startScreenRow, endScreenRow, screenLines)

    return if options.suppressChangeEvent

    changeEvent =
      start: startScreenRow
      end: endScreenRow - 1
      screenDelta: screenLines.length - (endScreenRow - startScreenRow)
      bufferDelta: bufferDelta

    if options.delayChangeEvent
      @pauseMarkerObservers()
      @pendingChangeEvent = changeEvent
    else
      @emitChanged(changeEvent, options.refreshMarkers)

  buildScreenLines: (startBufferRow, endBufferRow) ->
    screenLines = []
    regions = []
    rectangularRegion = null

    bufferRow = startBufferRow
    while bufferRow < endBufferRow
      tokenizedLine = @tokenizedBuffer.lineForScreenRow(bufferRow)

      if fold = @largestFoldStartingAtBufferRow(bufferRow)
        foldLine = tokenizedLine.copy()
        foldLine.fold = fold
        screenLines.push(foldLine)

        if rectangularRegion?
          regions.push(rectangularRegion)
          rectangularRegion = null

        foldedRowCount = fold.getBufferRowCount()
        regions.push(bufferRows: foldedRowCount, screenRows: 1)
        bufferRow += foldedRowCount
      else
        softWraps = 0
        while wrapScreenColumn = @findWrapColumn(tokenizedLine.text)
          [wrappedLine, tokenizedLine] = tokenizedLine.softWrapAt(wrapScreenColumn)
          screenLines.push(wrappedLine)
          softWraps++
        screenLines.push(tokenizedLine)

        if softWraps > 0
          if rectangularRegion?
            regions.push(rectangularRegion)
            rectangularRegion = null
          regions.push(bufferRows: 1, screenRows: softWraps + 1)
        else
          rectangularRegion ?= {bufferRows: 0, screenRows: 0}
          rectangularRegion.bufferRows++
          rectangularRegion.screenRows++

        bufferRow++

    if rectangularRegion?
      regions.push(rectangularRegion)

    {screenLines, regions}

  findMaxLineLength: (startScreenRow, endScreenRow, newScreenLines) ->
    if startScreenRow <= @longestScreenRow < endScreenRow
      @longestScreenRow = 0
      @maxLineLength = 0
      maxLengthCandidatesStartRow = 0
      maxLengthCandidates = @screenLines
    else
      maxLengthCandidatesStartRow = startScreenRow
      maxLengthCandidates = newScreenLines

    for screenLine, screenRow in maxLengthCandidates
      length = screenLine.text.length
      if length > @maxLineLength
        @longestScreenRow = maxLengthCandidatesStartRow + screenRow
        @maxLineLength = length

  handleBufferMarkersUpdated: =>
    if event = @pendingChangeEvent
      @pendingChangeEvent = null
      @emitChanged(event, false)

  handleBufferMarkerCreated: (marker) =>
    @createFoldForMarker(marker) if marker.matchesAttributes(@getFoldMarkerAttributes())
    @emit 'marker-created', @getMarker(marker.id)

  createFoldForMarker: (marker) ->
    bufferMarker = new DisplayBufferMarker({bufferMarker: marker, displayBuffer: this})
    @addDecorationForMarker(bufferMarker, type: 'gutter', class: 'folded')
    new Fold(this, marker)

  foldForMarker: (marker) ->
    @foldsByMarkerId[marker.id]
