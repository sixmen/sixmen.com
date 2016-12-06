_= require 'underscore'
async = require 'async'
{Evernote} = require 'evernote'
fs = require 'fs'
imagemagick = require 'imagemagick'
slug = require 'slug'

dir = "#{__dirname}/.evernote_cache"
asset_dir = "#{__dirname}/../static"
try
  oauthAccessToken = fs.readFileSync('.access_token', 'utf-8').trim()
catch
  oauthAccessToken = ''
notebookGuid = 'bb796ad3-926e-4600-bdc8-068a2a64995c'

try fs.mkdirSync dir

seqNums = {}
tags = {}
en_links = {}

updateSeqNum = (guid, seqNum) ->
  seqNums[guid] = seqNum if not seqNums[guid] or seqNums[guid] < seqNum

readSeqNums = ->
  files = fs.readdirSync dir
  for file in files
    if /(.*):(.*)\.enml/.test file
      updateSeqNum RegExp.$1, Number(RegExp.$2)
readSeqNums()

noteStore = new Evernote.Client(token: oauthAccessToken, sandbox: false).getNoteStore()

getResource = (mime, guid, callback) ->
  ext = switch mime
    when 'image/jpeg' then '.jpg'
    when 'image/png' then '.png'
    when 'image/gif' then '.gif'
    else ''
  path = "/evernote/#{guid}@2x#{ext}"
  if fs.existsSync asset_dir + path
    return callback null, path
  path = "/evernote/#{guid}#{ext}"
  if fs.existsSync asset_dir + path
    return callback null, path
  console.log 'Get resource: ' + guid
  noteStore.getResource guid, true, false, true, false, (error, data) ->
    fileName = data.attributes?.fileName or ''
    if /@2x/.test fileName
      path = "/evernote/#{guid}@2x#{ext}"
    buffer = new Buffer data.data._body
    fs.writeFileSync asset_dir + path, buffer
    callback null, path

uintArrayToHash = (array) ->
  str = ''
  for i in array
    c = i.toString(16)
    if c.length is 1
      str += '0'
    str += c
  return str

processMarkups = (content) ->
  while (pos = content.indexOf 'http://markup.sixmen.com')>=0
    start = content.lastIndexOf '<a', pos
    end = content.indexOf '</a>', pos
    if start < 0 or end < 0
      break
    markup = content.substr(start, end-start+4)
    markup = markup.replace /<[^>]*>/g, ''
    content = content.substr(0, start) + markup + content.substr(end+4)
  return content

getNoteContent = (note, callback) ->
  console.log 'Get note: ' + note.title + ',' + note.guid + ':' + note.updateSequenceNum
  noteStore.getNote note.guid, true, false, false, false, (error, data) ->
    console.log 'getNoteContent: ' + JSON.stringify(error) if error
    content = data.content

    content = processMarkups content

    medias = content.match(/<en-media.*?>(<\/en-media>)?/g) or []
    async.forEach medias, (media, callback) ->
      /hash="(.*?)"/.test media
      hash = RegExp.$1
      res = _.find data.resources, (r) ->
        return uintArrayToHash(r.data.bodyHash) is hash
      return callback null if not res
      getResource res.mime, res.guid, (error, path) ->
        if /@2x/.test path
          imagemagick.identify ['-format', '%w %h', asset_dir + path], (error, size) ->
            [width, height] = size.split ' '
            content = content.replace media, "<div style='max-width: #{width/2}px'>{{< evernoteImage #{res.guid} >}}</div>"
            callback null
        else
          content = content.replace media, "{{< evernoteImage #{res.guid} >}}"
          callback null
    , (error) ->
      callback content

getNote = (note, callback) ->
  filename = "#{dir}/#{note.guid}:#{note.updateSequenceNum}.enml"
  return callback true if fs.existsSync filename
  getNoteContent note, (content) ->
    return callback false if not content
    fs.writeFileSync filename, content
    callback true

getAllNotes = (callback) ->
  filter = new Evernote.NoteFilter notebookGuid: notebookGuid
  result_spec = new Evernote.NotesMetadataResultSpec includeTitle: true, includeCreated: true, includeUpdated: true, includeUpdateSequenceNum: true, includeTagGuids: true
  getList = (offset, callback) ->
    noteStore.findNotesMetadata filter, offset, 250, result_spec, (error, response) ->
      return callback error if error
      if response.totalNotes - response.startIndex - response.notes.length > 0
        getList response.startIndex + response.notes.length, (error, notes) ->
          return callback error if error
          [].push.apply notes, response.notes
          callback null, notes
      else
        callback null, response.notes
  getList 0, (error, notes) ->
    return callback error if error
    notes = _.filter notes, (note) -> note.tagGuids?.length > 0
    async.forEachSeries notes, (note, next) ->
      return next null if seqNums[note.guid] is note.updateSequenceNum
      getNote note, (success) ->
        return next null if not success
        next null
    , (error) ->
      callback error, notes

getTag = (tagGuid, callback) ->
  return callback null, tags[tagGuid] if tags[tagGuid]
  noteStore.getTag tagGuid, (error, tag) ->
    return callback null if error
    callback null, tags[tagGuid] = tag.name

replaceLinks = (content) ->
  links = content.match(/evernote:\/\/\/view\/\w*\/\w*\/[a-z0-9-]*\/[a-z0-9-]*\//g) or []
  links.forEach (link) ->
    /([a-z0-9-]*)\/$/.test link
    guid = RegExp.$1
    if en_links[guid]
      content = content.replace link, en_links[guid]
  return content

readNote = (filename) ->
  content = fs.readFileSync filename, 'utf-8'
  /<en-note.*?>([\s\S]*)<\/en-note>/.test content
  content = replaceLinks RegExp.$1
  return content

datePad = (num) ->
  return '0' + num if num<10
  return num

getCountForDate = (path, date) ->
  count = 1
  files = fs.readdirSync path
  for file in files
    count++ if file.substr(0, date.length) is date
  return count

initial_table = ['g','kk','n','d','tt','r','m','b','pp','s','ss','','j','jj','ch','k','t','p','h']
medial_table = ['a','ae','ya','yae','eo','e','yeo','ye','o','wa','wae','oe','yo','u','wo','we','wi','yu','eu','ui','i']
final_table = ['','k','k','k','n','n','n','t','l','l','l','l','l','l','l','l','m','p','p','t','t','ng','t','t','k','t','p','t']

romanize = (str) ->
  str = str.replace /./g, (ch) ->
    code = ch.charCodeAt(0)
    if code>=0xAC00 and code<=0xD7AF
      code = code - 0xAC00
      initial = Math.floor code / (21*28)
      medial = Math.floor (code - initial*21*28)/28
      final = code % 28
      ch = initial_table[initial]+medial_table[medial]+final_table[final]
    return ch
  return str

writePost = (note, tags, content) ->
  lang_tags = tags.filter (tag) -> tag.substr(0,5) is 'lang:'
  lang = lang_tags[0]?.substr 5
  return if not lang
  category_tags = tags.filter (tag) -> tag.substr(0,9) is 'category:'
  category = category_tags[0]?.substr 9
  return if not category
  tags = tags.filter (tag) -> not (tag.substr(0,5) is 'lang:' or tag.substr(0,9) is 'category:')

  front = []
  front.push '---'
  front.push "title: '#{note.title}'"
  front.push 'tags: [' + tags.join(', ') + ']'
  front.push "date: #{en_links[note.guid].substr(0, 10)}T0#{en_links[note.guid].substr(11).replace(/-.*/, '')}:00:00"
  front.push 'evernote: true'
  front.push '---'
  front.push ''
  content = front.join('\n') + content

  path = "../content/#{category}"
  filename = "#{path}/#{en_links[note.guid]}"

  fs.writeFileSync filename, content

collectEnLinks = (notes) ->
  prev_date = null
  count = 0
  for note in notes
    created = new Date(note.created)
    date = "#{created.getFullYear()}-#{datePad created.getMonth()+1}-#{datePad created.getDate()}"
    if prev_date is date
      count++
    else
      prev_date = date
      count = 1
    url_path = romanize note.title
    url_path = slug url_path
    url_path = url_path.replace /[*+~.()'"!:@]/g, ''
    en_links[note.guid] = "#{date}-#{count}-#{url_path}.html"

getAllNotes (error, notes) ->
  if error
    console.log 'getAllNotes fail', error
    return
  notes.sort (a, b) -> return a.created - b.created
  collectEnLinks notes
  async.forEachSeries notes, (note, next) ->
    filename = "#{dir}/#{note.guid}:#{note.updateSequenceNum}.enml"
    return next null if not fs.existsSync filename
    async.map note.tagGuids, getTag, (error, tags) ->
      content = readNote filename
      writePost note, tags, content
      next null
  , (error) ->
