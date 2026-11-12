local encoder = {}
package.loaded["tslua.api.encoder"] = encoder
for k, v in pairs(require("tslua.api.encoder.consts_generated")) do
    encoder[k] = v
end
require("tslua.api.encoder.bytebuf")
require("tslua.api.encoder.decoder")
require("tslua.api.encoder.decoder_generated")
require("tslua.api.encoder.encoder")
require("tslua.api.encoder.encoder_generated")
require("tslua.api.encoder.stringtable")
return encoder
