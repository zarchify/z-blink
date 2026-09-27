local compilation = require("@config/compilation")

export type Attributes = {
	export: true?,
	target: compilation.Target?,
	profile: compilation.Profile?,
	opaque: true?,
}

return nil
