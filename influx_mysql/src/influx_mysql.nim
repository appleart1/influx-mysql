# influx_mysql.nim
# Part of influx-mysql by Philip Wernersbach <philip.wernersbach@gmail.com>
#
# Copyright (c) 2016, Philip Wernersbach
#
# The source code in this file is licensed under the 2-Clause BSD License.
# See the LICENSE file in this project's root directory for the license
# text.

{.boundChecks: on.}

when defined(enabletheprofiler):
    import nimprof

import future
import strtabs
import strutils
import asyncdispatch
import asyncnet
import httpcore
import asynchttpserver
from net import BufferSize, TimeoutError
import lists
import tables
import json
import base64
import cgi
import times
import os
import sets

import qt5_qtsql
import snappy as snappy

import stdlib_extra
import reflists
import vendor/picohttpparser_c
import microasynchttpserver
import influxql_to_sql
import influx_line_protocol_to_sql
import influx_mysql_backend
import influx_mysql_cmdline

type
    URLParameterError = object of ValueError
    URLParameterNotFoundError = object of URLParameterError
    URLParameterInvalidError = object of URLParameterError

    DBQueryResultTransformationException = object of DBQueryException

    SeriesAndData = tuple
        fill: ResultFillType
        series: string
        order: OrderedTableRef[ref string, bool] not nil
        entries: SinglyLinkedRefList[Table[ref string, JSONField]] not nil

    # InfluxDB only supports four data types, which makes this easy
    # We add a fifth one so that we can properly support unsigned integers
    JSONFieldKind {.pure.} = enum
        Null,
        Integer,
        UInteger,
        Float,
        Boolean,
        String

    JSONField = object
        case kind: JSONFieldKind
        of JSONFieldKind.Null: discard
        of JSONFieldKind.Integer: intVal: int64
        of JSONFieldKind.UInteger: uintVal: uint64
        of JSONFieldKind.Float: floatVal: float64
        of JSONFieldKind.Boolean: booleanVal: bool
        of JSONFieldKind.String: stringVal: string

    QVariantType {.pure.} = enum
        Bool = 1
        Int = 2
        UInt = 3
        LongLong = 4
        ULongLong = 5
        Double = 6
        Char = 7
        String = 10
        Date = 14
        Time = 15
        DateTime = 16
        Long = 129
        Short = 130
        Char2 = 131
        ULong = 132
        UShort = 133
        UChar = 134
        Float = 135

    EpochFormat {.pure.} = enum
        RFC3339
        Hour
        Minute
        Second
        Millisecond
        Microsecond
        Nanosecond

    ReadLinesFutureContext* = ref tuple
        super: ReadLinesContext
        contentLength: int
        read: int
        noReadsCount: int
        readNow: string
        request: Request
        params: StringTableRef
        retFuture: Future[ReadLinesFutureContext]
        routerResult: Future[void]

const QUERY_HTTP_METHODS = "GET, POST"
const WRITE_HTTP_METHODS = "POST"
const PING_HTTP_METHODS = "GET, HEAD"

const cacheControlZeroAge: string = "0"

when getEnv("cachecontrolmaxage") != "":
    const cachecontrolmaxage: string = getEnv("cachecontrolmaxage")
else:
    const cachecontrolmaxage: string = "0"

const cacheControlDontCacheHeader = "private, max-age=" & cacheControlZeroAge & ", s-maxage=" & cacheControlZeroAge & ", no-cache"
const cacheControlDoCacheHeader = "public, max-age=" & cachecontrolmaxage & ", s-maxage=" & cachecontrolmaxage

var corsAllowOrigin: cstring = nil

template JSON_CONTENT_TYPE_RESPONSE_HEADERS(): HttpHeaders =
    newHttpHeaders([("Content-Type", "application/json"), ("Cache-Control", cacheControlDoCacheHeader)])

template JSON_CONTENT_TYPE_NO_CACHE_RESPONSE_HEADERS(): HttpHeaders =
    newHttpHeaders([("Content-Type", "application/json"), ("Cache-Control", cacheControlDontCacheHeader)])

template TEXT_CONTENT_TYPE_NO_CACHE_RESPONSE_HEADERS(): HttpHeaders =
    newHttpHeaders([("Content-Type", "text/plain"), ("Cache-Control", cacheControlDontCacheHeader)])

template TEXT_CONTENT_TYPE_RESPONSE_HEADERS(): HttpHeaders =
    newHttpHeaders([("Content-Type", "text/plain"), ("Cache-Control", cacheControlDoCacheHeader)])

template PING_RESPONSE_HEADERS(): HttpHeaders =
    newHttpHeaders([("Content-Type", "text/plain"), ("Cache-Control", cacheControlDontCacheHeader), ("Date", date), ("X-Influxdb-Version", "0.9.3-compatible-influxmysql")])

template REGISTRATION_DATA_RESPONSE_HEADERS(): HttpHeaders =
    newHttpHeaders([("Content-Type", "text/plain"), ("Cache-Control", cacheControlDoCacheHeader), ("Date", date), ("X-Influxdb-Version", "0.9.3-compatible-influxmysql")])

proc getParams(request: Request): StringTableRef =
    result = newStringTable(modeCaseSensitive)

    for part in request.url.query.split('&'):
        let keyAndValue = part.split('=')

        if (keyAndValue.len == 2):
            result[keyAndValue[0]] = keyAndValue[1].decodeUrl

proc toRFC3339JSONField(dateTime: QDateTimeObj): JSONField =
    var timeStringConst = dateTime.toQStringObj("yyyy-MM-ddThh:mm:ss.zzz000000Z").toUtf8.constData.umc

    result.kind = JSONFieldKind.String
    result.stringVal.shallowCopy(timeStringConst.strdup)
    shallow(result.stringVal)

proc toJSONField(dateTime: QDateTimeObj, period: uint64, epoch: EpochFormat): JSONField =
    case epoch:
    of EpochFormat.RFC3339:
        if period != 1:
            let dateTimeBinned = newQDateTimeObj(qint64((uint64(dateTime.toMSecsSinceEpoch) div period) * period), QtUtc)
            result = dateTimeBinned.toRFC3339JSONField
        else:
            result = dateTime.toRFC3339JSONField
    of EpochFormat.Hour:
        result.kind = JSONFieldKind.UInteger
        result.uintVal = ((uint64(dateTime.toMSecsSinceEpoch) div period) * period) div 3600000
    of EpochFormat.Minute:
        result.kind = JSONFieldKind.UInteger
        result.uintVal = ((uint64(dateTime.toMSecsSinceEpoch) div period) * period) div 60000
    of EpochFormat.Second:
        result.kind = JSONFieldKind.UInteger
        result.uintVal = ((uint64(dateTime.toMSecsSinceEpoch) div period) * period) div 1000
    of EpochFormat.Millisecond:
        result.kind = JSONFieldKind.UInteger
        result.uintVal = (uint64(dateTime.toMSecsSinceEpoch) div period) * period
    of EpochFormat.Microsecond:
        result.kind = JSONFieldKind.UInteger
        result.uintVal = ((uint64(dateTime.toMSecsSinceEpoch) div period) * period) * 1000
    of EpochFormat.Nanosecond:
        result.kind = JSONFieldKind.UInteger
        result.uintVal = ((uint64(dateTime.toMSecsSinceEpoch) div period) * period) * 1000000

proc toJSONField(record: QSqlRecordObj, i: cint, period: uint64, epoch: EpochFormat): JSONField =
    if not record.isNull(i):
        var valueVariant = record.value(i)

        case QVariantType(valueVariant.userType):
        of QVariantType.Date, QVariantType.Time, QVariantType.DateTime:
            var dateTime = valueVariant.toQDateTimeObj
            dateTime.setTimeSpec(QtUtc)

            result = dateTime.toJSONField(period, epoch)

        of QVariantType.Bool:

            result.kind = JSONFieldKind.Boolean
            result.booleanVal = valueVariant
        
        of QVariantType.Int, QVariantType.LongLong, QVariantType.Char, QVariantType.Long,
            QVariantType.Short, QVariantType.Char2: 

            result.kind = JSONFieldKind.Integer
            result.intVal = valueVariant

        of QVariantType.UInt, QVariantType.ULongLong, QVariantType.ULong,
            QVariantType.UShort, QVariantType.UChar:

            result.kind = JSONFieldKind.UInteger
            result.uintVal = valueVariant

        of QVariantType.Double, QVariantType.Float:

            result.kind = JSONFieldKind.Float
            result.floatVal = valueVariant

        of QVariantType.String:

            var valueStringConst = valueVariant.toQStringObj.toUtf8.constData.umc

            result.kind = JSONFieldKind.String
            result.stringVal.shallowCopy(valueStringConst.strdup)
            shallow(result.stringVal)

        else:

            raise newException(ValueError, "Cannot unpack QVariantObj of type \"" & $valueVariant.userType & "\"!")
    else:
        result.kind = JSONFieldKind.Null

proc `==`(a: JSONField, b: JSONField): bool =
    if a.kind == b.kind:
        case a.kind:
        of JSONFieldKind.Null: result = false
        of JSONFieldKind.Integer: result = (a.intVal == b.intVal)
        of JSONFieldKind.UInteger: result = (a.uintVal == b.uintVal)
        of JSONFieldKind.Float: result = (a.floatVal == b.floatVal)
        of JSONFieldKind.Boolean: result = (a.booleanVal == b.booleanVal)
        of JSONFieldKind.String: result = (a.stringVal == b.stringVal)
    else:
        result = false

# This function can probably be optimized more. It bugs me that we have to 
# convert lastTime to a JSONField on each iteration, just to compare the
# lastTime to the newTime. The problem is that not only do we have to take into
# account the actual times, we have to take into account lastTime's and
# newTime's value in the context of both the period and the epoch resolution. I
# failed to find another way to *correctly* take all of this into account, that
# is more efficient.
#
# It could be worse though. This function is no less efficient when we do need
# to fill in an entry, since we just assign the lastTime's temporary JSONField
# to the permanent fill entry. But when we don't need to fill, we create a
# JSONField for the comparison that is then thrown out.
#
# This function is in the query fast path, so any optimizations here will yield
# a huge performance improvement.
proc addFill(entries: SinglyLinkedRefList[Table[ref string, JSONField]] not nil, order: OrderedTableRef[ref string, bool] not nil,
                lastTime: QDateTimeObj, newTime: QDateTimeObj, period: uint64, epoch: EpochFormat, timeInterned: ref string) =

    var lastTime = lastTime

    let newTimeMsecs = newTime.toMSecsSinceEpoch
    let newTimeField = newTime.toJSONField(period, epoch)

    lastTime = lastTime.addMSecs(qint64(period))

    while true:
        if (newTimeMsecs - lastTime.toMSecsSinceEpoch) < 1:
            break

        let lastTimeField = lastTime.toJSONField(period, epoch)

        if lastTimeField == newTimeField:
            break

        var entryValues = newTable[ref string, JSONField]()
        entryValues[timeInterned] = lastTimeField

        entries.append(entryValues)

        lastTime = lastTime.addMSecs(qint64(period))

proc runDBQueryAndUnpack(sql: cstring, series: string, period: uint64,
                         fill: ResultFillType, fillMin: uint64, fillMax: uint64,
                         dizcard: HashSet[string], epoch: EpochFormat, result: var DoublyLinkedList[SeriesAndData], internedStrings: var Table[string, ref string],
                         dbName: string, dbUsername: string, dbPassword: string)  =

    let jsonPeriod = if period != 0: period else: uint64(1)
    var zeroDateTime = newQDateTimeObj(0, QtUtc)
    let timeInterned = internedStrings["time"]

    useDB(dbName, dbUsername, dbPassword):
        block:
            "SET time_zone='+0:00'".useQuery(database)

        sql.useQuery(database)

        var entries = newSinglyLinkedRefList[Table[ref string, JSONField]]()
        var seriesAndData: SeriesAndData = (fill: fill, series: series, order: cast[OrderedTableRef[ref string, bool] not nil](newOrderedTable[ref string, bool]()), 
                                entries: entries)
        result.append(seriesAndData)

        var order = seriesAndData.order

        var lastTime = if fillMin > uint64(period): newQDateTimeObj(qint64(fillMin - period), QtUtc) else: zeroDateTime

        while query.next() == true:
            var record = query.record
            let count = record.count - 1

            var entryValues = newTable[ref string, JSONField]()

            if fill != ResultFillType.NONE:
                # For strict InfluxDB compatibility:
                #
                # InfluxDB will automatically return NULLs if there is no data for that GROUP BY timeframe block.
                # SQL databases do not do this, they return nothing if there is no data. So we need to add these
                # NULLs.
                var newTime: QDateTimeObj = record.value("time")
                newTime.setTimeSpec(QtUtc)

                if (period > uint64(0)) and (zeroDateTime < lastTime):
                    entries.addFill(order, lastTime, newTime, period, epoch, timeInterned)

                lastTime = newTime

            for i in countUp(0, count):
                var fieldNameConst = record.fieldName(i).toUtf8.constData.umc
                var fieldName: string = fieldNameConst.strdup

                if (not dizcard.contains(fieldName)):
                    let fieldNameLen = fieldName.len

                    # For strict InfluxDB compatibilty:
                    #
                    # We only return the name of the functions as the field, and not the name and the arguments.
                    #
                    # We also change "AVG" to "mean" since we change "mean" to "AVG" in the InfluxQL to SQL conversion.
                    if (fieldName[fieldNameLen-1] == ')') and (fieldNameLen > 4) and
                        (fieldName[0] == 'A') and (fieldName[1] == 'V') and (fieldName[2] == 'G') and (fieldName[3] == '('):

                        fieldName = "mean"

                    var fieldNameInterned = internedStrings.getOrDefault(fieldName)
                    if fieldNameInterned == nil:
                        new(fieldNameInterned)
                        fieldNameInterned[] = fieldName

                        internedStrings[fieldName] = fieldNameInterned

                    discard order.hasKeyOrPut(fieldNameInterned, true)

                    if fieldNameInterned != timeInterned:
                        entryValues[fieldNameInterned] = record.toJSONField(i, 1, epoch)
                    else:
                        entryValues[fieldNameInterned] = record.toJSONField(i, jsonPeriod, epoch)

            entries.append(entryValues)

        # Add fills until fillMax.
        if fill != ResultFillType.NONE:
            # For strict InfluxDB compatibility:
            #
            # InfluxDB will automatically return NULLs if there is no data for that GROUP BY timeframe block.
            # SQL databases do not do this, they return nothing if there is no data. So we need to add these
            # NULLs.
            var newTime = newQDateTimeObj(qint64(fillMax), QtUtc)

            if (period > uint64(0)) and (zeroDateTime < lastTime):
                entries.addFill(order, lastTime, newTime, period, epoch, timeInterned)

            lastTime = newTime


converter toJsonNode(field: JSONField): JsonNode =
    case field.kind:
    of JSONFieldKind.Null: result = newJNull()
    of JSONFieldKind.Integer: result = newJInt(BiggestInt(field.intVal))
    of JSONFieldKind.UInteger: result = newJInt(BiggestInt(field.uintVal))
    of JSONFieldKind.Float: result = newJFloat(field.floatVal)
    of JSONFieldKind.Boolean: result = newJBool(field.booleanVal)
    of JSONFieldKind.String: result = newJString(field.stringVal)

proc toJsonNode(kv: SeriesAndData, fill: bool, fillField: JSONField): JsonNode =
    result = newJObject()
    var seriesArray = newJArray()
    var seriesObject = newJObject()

    seriesObject.add("name", newJString(kv.series))

    var columns = newJArray()

    for column in kv.order.keys:
        columns.add(newJString(column[]))

    seriesObject.add("columns", columns)

    var valuesArray = newJArray()

    if fill:
        for entry in kv.entries.items:
            var entryArray = newJArray()

            for column in kv.order.keys:
                entryArray.add(entry.mgetOrPut(column, fillField))

            valuesArray.add(entryArray)
    else:
        for entry in kv.entries.items:
            var entryArray = newJArray()

            for column in kv.order.keys:
                entryArray.add(entry[column])

            valuesArray.add(entryArray)

    seriesObject.add("values", valuesArray)

    seriesArray.add(seriesObject)
    result.add("series", seriesArray)

proc toQueryResponse(ev: DoublyLinkedList[SeriesAndData]): string =
    var json = newJObject()
    var results = newJArray()

    for keyAndValue in ev.items:
        var fill: bool
        var fillField: JSONField

        case keyAndValue.fill:
        of ResultFillType.NULL:
            fillField = JSONField(kind: JSONFieldKind.Null)
            fill = true
        of ResultFillType.ZERO:
            fillField = JSONField(kind: JSONFieldKind.UInteger, uintVal: 0)
            fill = true
        else:
            fill = false

        results.add(keyAndValue.toJsonNode(fill, fillField))

    json.add("results", results)
    result = $json

# Applies the specified results transformation to the last series in the list.
proc applyResultTransformation(ev: DoublyLinkedList[SeriesAndData], resultTransform: SQLResultTransform, internedStrings: var Table[string, ref string]) =
    case resultTransform:
    of SQLResultTransform.NONE:
        discard
    of SQLResultTransform.SHOW_DATABASES:
        let series = ev.tail
        let databaseInterned = internedStrings.getOrDefault("Database")

        if (series[].value.series.len == 0) and (series[].value.order.len == 1) and (databaseInterned != nil) and (series[].value.order.hasKey(databaseInterned)):
            var nameInterned = internedStrings.getOrDefault("name")
            if nameInterned == nil:
                new(nameInterned)
                nameInterned[] = "name"

                internedStrings["name"] = nameInterned

            series[].value.series = "databases"

            # Replacing the order table is a workaround, as the standard library doesn't have a del() implementation for
            # OrderedTables.
            series[].value.order = cast[OrderedTableRef[ref string, bool] not nil](newOrderedTable([(nameInterned, true)]))

            for entry in series[].value.entries.items:
                entry[nameInterned] = entry[databaseInterned]
                entry.del(databaseInterned)

    of SQLResultTransform.UNKNOWN:
        raise newException(DBQueryResultTransformationException, "Tried to apply unknown transformation!")

proc withCorsIfNeeded(headers: HttpHeaders, allowMethods: string, accessControlMaxAge: string): HttpHeaders =
    if corsAllowOrigin != nil:
        if allowMethods != nil:
            headers["Access-Control-Allow-Methods"] = allowMethods

        if accessControlMaxAge != nil:
            headers["Access-Control-Max-Age"] = accessControlMaxAge

        headers["Access-Control-Allow-Origin"] = $corsAllowOrigin
        headers["Access-Control-Allow-Headers"] = "Accept, Origin, Authorization"
        headers["Access-Control-Allow-Credentials"] = "true"

    result = headers

proc withCorsIfNeeded(headers: HttpHeaders, allowMethods: string): HttpHeaders =
    if headers["Cache-Control"] == cacheControlDoCacheHeader:
        result = headers.withCorsIfNeeded(allowMethods, cachecontrolmaxage)
    elif headers["Cache-Control"] == cacheControlDontCacheHeader:
        result = headers.withCorsIfNeeded(allowMethods, cacheControlZeroAge)
    else:
        result = headers.withCorsIfNeeded(allowMethods, nil)

template withCorsIfNeeded(headers: HttpHeaders, allowMethod: HttpMethod): HttpHeaders =
    headers.withCorsIfNeeded($allowMethod)

proc getOrHeadPing(request: Request): Future[void] =
    let date = getTime().getGMTime.format("ddd, dd MMM yyyy HH:mm:ss 'GMT'")
    result = request.respond(Http204, "", PING_RESPONSE_HEADERS.withCorsIfNeeded(PING_HTTP_METHODS))

proc basicAuthToUrlParam(request: var Request) =
    if not request.headers.hasKey("Authorization"):
        return

    let parts = request.headers["Authorization"].split(' ')

    if (parts.len != 2) or (parts[0] != "Basic"):
        return

    let userNameAndPassword = base64.decode(parts[1]).split(':')

    if (userNameAndPassword.len != 2):
        return

    request.url.query.add("&u=")
    request.url.query.add(userNameAndPassword[0].encodeUrl)

    request.url.query.add("&p=")
    request.url.query.add(userNameAndPassword[1].encodeUrl)

proc getQuery(request: Request, params: StringTableRef): Future[void] =
    var internedStrings = initTable[string, ref string]()

    var timeInterned: ref string
    new(timeInterned)
    timeInterned[] = "time"

    internedStrings["time"] = timeInterned

    var entries = initDoublyLinkedList[SeriesAndData]()
    let nowTime = uint64(currentQDateTimeUtc().toMSecsSinceEpoch)

    try:
        GC_disable()

        let urlQuery = params["q"]
        let specifiedEpochFormat = params.getOrDefault("epoch")

        var epoch = EpochFormat.RFC3339

        if specifiedEpochFormat != "":
            case specifiedEpochFormat:
            of "h": epoch = EpochFormat.Hour
            of "m": epoch = EpochFormat.Minute
            of "s": epoch = EpochFormat.Second
            of "ms": epoch = EpochFormat.Millisecond
            of "u": epoch = EpochFormat.Microsecond
            of "ns": epoch = EpochFormat.Nanosecond
            else:
                raise newException(URLParameterInvalidError, "Invalid epoch parameter specified!")

        if urlQuery == nil:
            raise newException(URLParameterNotFoundError, "No \"q\" query parameter specified!")

        var dbName = ""
        var dbUsername = ""
        var dbPassword = ""

        if params.hasKey("db"):
            dbName = params["db"]

        if params.hasKey("u"):
            dbUsername = params["u"]

        if params.hasKey("p"):
            dbPassword = params["p"]

        var cache = true

        for line in urlQuery.splitInfluxQlStatements:
            var series: string
            var period = uint64(0)
            var resultTransform = SQLResultTransform.UNKNOWN
            var fill = ResultFillType.NONE
            var fillMin = uint64(0)
            var fillMax = uint64(currentQDateTimeUtc().toMSecsSinceEpoch)
            var dizcard = initSet[string]()

            let sql = line.influxQlToSql(resultTransform, series, period, fill, fillMin, fillMax, cache, dizcard, nowTime)

            when defined(logrequests):
                stdout.write("/query: ")
                stdout.write(line)
                stdout.write(" --> ")
                stdout.writeLine(sql)

            try:
                sql.runDBQueryAndUnpack(series, period, fill, fillMin, fillMax, dizcard, epoch, entries, internedStrings, dbName, dbUsername, dbPassword)
                entries.applyResultTransformation(resultTransform, internedStrings)
            except DBQueryException:
                stdout.write("/query: ")
                stdout.write(line)
                stdout.write(" --> ")
                stdout.writeLine(sql)
                raise getCurrentException()

        if cache != false:
            result = request.respond(Http200, entries.toQueryResponse, JSON_CONTENT_TYPE_RESPONSE_HEADERS.withCorsIfNeeded(QUERY_HTTP_METHODS))
        else:
            result = request.respond(Http200, entries.toQueryResponse, JSON_CONTENT_TYPE_NO_CACHE_RESPONSE_HEADERS.withCorsIfNeeded(QUERY_HTTP_METHODS))
    finally:
        try:
            # SQLEntryValues.entries is a manually allocated object, so we
            # need to free it.
            for entry in entries.items:
                entry.entries.removeAll
        finally:
            GC_enable()

template getQuery(request: Request): Future[void] =
    getQuery(request, getParams(request))

proc postQuery(request: Request): Future[void] =
    let params = getParams(request)

    if (params.getOrDefault("db") != "") or (params.getOrDefault("q") != "SHOW DIAGNOSTICS for 'registration'"):
        result = getQuery(request, params)
    else:
        # If the query is POSTed, and the database is empty, and the query is the registration diagnostics query,
        # then the InfluxDB client is requesting the server's registration data. This isn't an actual InfluxDB server,
        # so we aren't officially registered.
        let date = getTime().getGMTime.format("ddd, dd MMM yyyy HH:mm:ss 'GMT'")
        result = request.respond(Http200, "{\"results\":[{}]}", REGISTRATION_DATA_RESPONSE_HEADERS.withCorsIfNeeded(QUERY_HTTP_METHODS))

import posix

when defined(linux):
    import linux
else:
    const MSG_DONTWAIT = 0

proc destroyReadLinesFutureContext(context: ReadLinesFutureContext not nil) =
    if not context.super.destroyed:
        try:
            GC_disable()

            context.super.destroyReadLinesContext
            context.super.destroyed = false

            # Probably not needed, but better safe than sorry
            if not context.retFuture.finished:
                asyncCheck context.retFuture
                context.retFuture.complete(nil)

            # Probably not needed, but better safe than sorry
            if not context.routerResult.finished:
                context.routerResult.complete

            context.super.destroyed = true
        finally:
            GC_enable()

proc respondError(request: Request, e: ref Exception, eMsg: string) =
    stderr.write(e.getStackTrace())
    stderr.write("Error: unhandled exception: ")
    stderr.writeLine(eMsg)

    asyncCheck request.respond(Http400, $( %*{ "error": eMsg } ), JSON_CONTENT_TYPE_NO_CACHE_RESPONSE_HEADERS.withCorsIfNeeded(request.reqMethod))

proc postReadLines(context: ReadLinesFutureContext not nil) =
    try:
        GC_disable()

        var chunkLen = context.contentLength - context.read
        while true:
            if chunkLen > 0:
                if chunkLen > BufferSize:
                    chunkLen = BufferSize

                # Do a non-blocking read of data from the socket
                context.request.client.rawRecv(context.readNow, chunkLen, MSG_DONTWAIT)
                if context.readNow.len < 1:
                    # We didn't get data, check if client disconnected
                    if (errno != EAGAIN) and (errno != EWOULDBLOCK):
                        raise newException(IOError, "Client socket disconnected!")
                    else:
                        # Client didn't disconnect, it's just slow.
                        # Start penalizing the client by responding to it slower.
                        # This prevents slowing down other async connections because
                        # of one slow client.
                        context.noReadsCount += 1

                        if context.noReadsCount > 40:
                            # After 40 reads, we've waited a total of more than 15 seconds.
                            # Timeout, probably gave us the wrong Content-Length.
                            raise newException(TimeoutError, "Client is too slow in sending POST body! (Is Content-Length correct?)")

                        # Client gets one freebie
                        if context.noReadsCount > 1:
                            # For every read with no data after the freebie, sleep for
                            # an additional 20 milliseconds
                            let sleepFuture = sleepAsync((context.noReadsCount - 1) * 20)

                            sleepFuture.callback = (proc(future: Future[void]) =
                                context.postReadLines
                            )
                            return

                        continue
                else:
                    # We got data, reset the penalty
                    context.noReadsCount = 0

                context.read += context.readNow.len
                context.super.lines.add(context.readNow)

            chunkLen = context.contentLength - context.read

            if (not context.super.compressed) or (chunkLen <= 0):
                context.super.uncompressOverwrite
                context.super.linesToSQLEntryValues

            if chunkLen <= 0:
                break

        context.routerResult.complete
        context.retFuture.complete(context)
    except IOError, ValueError, TimeoutError:
        context.routerResult.complete

        context.request.respondError(getCurrentException(), getCurrentExceptionMsg())
        context.destroyReadLinesFutureContext
    finally:
        GC_enable()

proc postReadLines(request: Request, routerResult: Future[void]): Future[ReadLinesFutureContext] =
    var contentLength = 0
    var compressed = false
    var contentEncoding: string = nil

    result = newFuture[ReadLinesFutureContext]("postReadLines")

    if request.headers.hasKey("Content-Length"):
        contentLength = request.headers["Content-Length"].parseInt

    if request.headers.hasKey("Content-Encoding"):
        contentEncoding = request.headers["Content-Encoding"]

    if contentLength == 0:
        result.fail(newException(IOError, "Content-Length required, but not provided!"))
        #result = request.respond(Http400, "Content-Length required, but not provided!", TEXT_CONTENT_TYPE_NO_CACHE_RESPONSE_HEADERS.withCorsIfNeeded(WRITE_HTTP_METHODS))
        return

    if contentEncoding != nil:
        if contentEncoding == "snappy":
            compressed = true
        else:
            result.fail(newException(IOError, "Content-Encoding \"" & contentEncoding & "\" not supported!"))
            return

    let params = getParams(request)

    var context: ReadLinesFutureContext not nil
    new(context, destroyReadLinesFutureContext)
    context[] = (super: newReadLinesContext(compressed, ("true" == params.getOrDefault("schemaful")), nil), 
        contentLength: contentLength, read: 0, noReadsCount: 0, readNow: newString(BufferSize), request: request, params: params, retFuture: result, routerResult: routerResult)

    context.super.lines = request.client.recvWholeBuffer
    context.read = context.super.lines.len

    context.postReadLines

proc mget[T](future: Future[T]): var T = asyncdispatch.mget(cast[FutureVar[T]](future))

proc postWriteProcess(ioResult: Future[ReadLinesFutureContext]) =
    try:
        GC_disable()

        var dbName = ""
        var dbUsername = ""
        var dbPassword = ""

        let context = ioResult.read

        if context != nil:
            if context.params.hasKey("db"):
                dbName = context.params["db"]

            if context.params.hasKey("u"):
                dbUsername = context.params["u"]

            if context.params.hasKey("p"):
                dbPassword = context.params["p"]

            if context.super.schemaful != nil:
                context.super.schemaful.inserts.processSQLTableInsertsAndRunDBQuery(dbName, dbUsername, dbPassword)
            else:
                context.super.schemaless.entries.processSQLEntryValuesAndRunDBQuery(dbName, dbUsername, dbPassword)

            asyncCheck context.request.respond(Http204, "", TEXT_CONTENT_TYPE_NO_CACHE_RESPONSE_HEADERS.withCorsIfNeeded(WRITE_HTTP_METHODS))

            context.destroyReadLinesFutureContext
        else:
            raise newException(Exception, "Context is nil! (This cannot happen under regular runtime.)")
    except IOError, ValueError, TimeoutError:
        let context = ioResult.mget

        if context != nil:
            context.request.respondError(getCurrentException(), getCurrentExceptionMsg())
            context.destroyReadLinesFutureContext
        else:
            raise newException(Exception, "Context is nil! (This cannot happen under regular runtime.)")
    finally:
            GC_enable()

template postWrite(request: Request, routerResult: Future[void]) =
    let ioResult = request.postReadLines(routerResult)
    ioResult.callback = postWriteProcess

template optionsCors(request: Request, allowMethods: string): Future[void] =
    request.respond(Http200, "", TEXT_CONTENT_TYPE_RESPONSE_HEADERS.withCorsIfNeeded(allowMethods))

proc routerHandleError(request: Request, processingResult: Future[void]) =
    try:
        processingResult.read
    except IOError, ValueError, TimeoutError:
        request.respondError(getCurrentException(), getCurrentExceptionMsg())

proc router(request: Request): Future[void] =
    var request = request

    result = newFuture[void]("router")

    try:
        request.basicAuthToUrlParam

        when defined(logrequests):
            stdout.write(request.url.path)
            stdout.write('?')
            stdout.writeLine(request.url.query)

        if (request.reqMethod == HttpGet) and (request.url.path == "/query"):
            result.complete
            request.getQuery.callback = (x: Future[void]) => routerHandleError(request, x)
            return
        elif (request.reqMethod == HttpPost) and (request.url.path == "/write"):
            request.postWrite(result)
            return
        elif (request.reqMethod == HttpPost) and (request.url.path == "/query"):
            result.complete
            request.postQuery.callback = (x: Future[void]) => routerHandleError(request, x)
            return
        elif ((request.reqMethod == HttpGet) or (request.reqMethod == HttpHead)) and (request.url.path == "/ping"):
            result.complete
            request.getOrHeadPing.callback = (x: Future[void]) => routerHandleError(request, x)
            return
        elif (request.reqMethod == HttpOptions) and (corsAllowOrigin != nil):
            result.complete

            case request.url.path:
            of "/query":
                request.optionsCors(QUERY_HTTP_METHODS).callback = (x: Future[void]) => routerHandleError(request, x)
                return
            of "/write":
                request.optionsCors(WRITE_HTTP_METHODS).callback = (x: Future[void]) => routerHandleError(request, x)
                return
            of "/ping":
                request.optionsCors(PING_HTTP_METHODS).callback = (x: Future[void]) => routerHandleError(request, x)
                return
            else:
                discard

        if not result.finished:
            result.complete

        # Fall through on purpose, we didn't have a matching route.
        let responseMessage = "Route not found for [reqMethod=" & $request.reqMethod & ", url=" & request.url.path & "]"
        stdout.writeLine(responseMessage)

        request.respond(Http400, responseMessage, TEXT_CONTENT_TYPE_NO_CACHE_RESPONSE_HEADERS.withCorsIfNeeded(request.reqMethod)).callback = (x: Future[void]) => routerHandleError(request, x)
    except IOError, ValueError, TimeoutError:
        if not result.finished:
            result.complete

        request.respondError(getCurrentException(), getCurrentExceptionMsg())

proc quitUsage() =
    stderr.writeLine("Usage: influx_mysql <mysql address:mysql port> <influxdb address:influxdb port> [cors allowed origin]")
    quit(QuitFailure)

cmdlineMain():
    if params == 3:
        var corsAllowOriginString = paramStr(3)

        corsAllowOrigin = cast[cstring](allocShared0(corsAllowOriginString.len + 1))
        copyMem(addr(corsAllowOrigin[0]), addr(corsAllowOriginString[0]), corsAllowOriginString.len)
    elif params > 3:
        stderr.writeLine("Error: Too many arguments specified!")
        quitUsage()

    try:
        waitFor newMicroAsyncHttpServer().serve(Port(httpServerPort), router, httpServerHostname)
    except Exception:
        let e = getCurrentException()
        stderr.write(e.getStackTrace())
        stderr.write("Error: unhandled exception: ")
        stderr.writeLine(getCurrentExceptionMsg())

        quit(QuitFailure)
