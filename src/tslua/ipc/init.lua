local ipc = {}
package.loaded["tslua.ipc"] = ipc
require("tslua.ipc.conn")
require("tslua.ipc.conn_async")
require("tslua.ipc.conn_sync")
require("tslua.ipc.protocol")
require("tslua.ipc.protocol_jsonrpc")
require("tslua.ipc.timing")
require("tslua.ipc.transport")
require("tslua.ipc.pipe")
require("tslua.ipc.process")
return ipc
