local printer = require("tslua.printer")

-- Priority is a Go struct { Value int }: { value = n }.
-- EmitHelper is a Go struct: { name, scoped, text, textCallback, priority, dependencies, importName }.

function printer.compareEmitHelpers(x, y)
    if x == y then
        return 0
    end
    if x.priority == y.priority then
        return 0
    end
    if x.priority == nil then
        return 1
    end
    if y.priority == nil then
        return -1
    end
    return x.priority.value - y.priority.value
end

-- TypeScript Helpers

printer.decorateHelper = {
    name = "typescript:decorate",
    importName = "__decorate",
    scoped = false,
    priority = { value = 2 },
    text = [[var __decorate = (this && this.__decorate) || function (decorators, target, key, desc) {
    var c = arguments.length, r = c < 3 ? target : desc === null ? desc = Object.getOwnPropertyDescriptor(target, key) : desc, d;
    if (typeof Reflect === "object" && typeof Reflect.decorate === "function") r = Reflect.decorate(decorators, target, key, desc);
    else for (var i = decorators.length - 1; i >= 0; i--) if (d = decorators[i]) r = (c < 3 ? d(r) : c > 3 ? d(target, key, r) : d(target, key)) || r;
    return c > 3 && r && Object.defineProperty(target, key, r), r;
};]],
}

printer.metadataHelper = {
    name = "typescript:metadata",
    importName = "__metadata",
    scoped = false,
    priority = { value = 3 },
    text = [[var __metadata = (this && this.__metadata) || function (k, v) {
    if (typeof Reflect === "object" && typeof Reflect.metadata === "function") return Reflect.metadata(k, v);
};]],
}

printer.paramHelper = {
    name = "typescript:param",
    importName = "__param",
    scoped = false,
    priority = { value = 4 },
    text = [[var __param = (this && this.__param) || function (paramIndex, decorator) {
    return function (target, key) { decorator(target, key, paramIndex); }
};]],
}

-- ESNext Helpers

printer.addDisposableResourceHelper = {
    name = "typescript:addDisposableResource",
    importName = "__addDisposableResource",
    scoped = false,
    text = [[var __addDisposableResource = (this && this.__addDisposableResource) || function (env, value, async) {
    if (value !== null && value !== void 0) {
        if (typeof value !== "object" && typeof value !== "function") throw new TypeError("Object expected.");
        var dispose, inner;
        if (async) {
            if (!Symbol.asyncDispose) throw new TypeError("Symbol.asyncDispose is not defined.");
            dispose = value[Symbol.asyncDispose];
        }
        if (dispose === void 0) {
            if (!Symbol.dispose) throw new TypeError("Symbol.dispose is not defined.");
            dispose = value[Symbol.dispose];
            if (async) inner = dispose;
        }
        if (typeof dispose !== "function") throw new TypeError("Object not disposable.");
        if (inner) dispose = function() { try { inner.call(this); } catch (e) { return Promise.reject(e); } };
        env.stack.push({ value: value, dispose: dispose, async: async });
    }
    else if (async) {
        env.stack.push({ async: true });
    }
    return value;
};]],
}

printer.disposeResourcesHelper = {
    name = "typescript:disposeResources",
    importName = "__disposeResources",
    scoped = false,
    text = [[var __disposeResources = (this && this.__disposeResources) || (function (SuppressedError) {
    return function (env) {
        function fail(e) {
            env.error = env.hasError ? new SuppressedError(e, env.error, "An error was suppressed during disposal.") : e;
            env.hasError = true;
        }
        var r, s = 0;
        function next() {
            while (r = env.stack.pop()) {
                try {
                    if (!r.async && s === 1) return s = 0, env.stack.push(r), Promise.resolve().then(next);
                    if (r.dispose) {
                        var result = r.dispose.call(r.value);
                        if (r.async) return s |= 2, Promise.resolve(result).then(next, function(e) { fail(e); return next(); });
                    }
                    else s |= 1;
                }
                catch (e) {
                    fail(e);
                }
            }
            if (s === 1) return env.hasError ? Promise.reject(env.error) : Promise.resolve();
            if (env.hasError) throw env.error;
        }
        return next();
    };
})(typeof SuppressedError === "function" ? SuppressedError : function (error, suppressed, message) {
    var e = new Error(message);
    return e.name = "SuppressedError", e.error = error, e.suppressed = suppressed, e;
});]],
}

-- Class Fields Helpers

--
-- Parameters:
--  @param receiver — The object from which the private member will be read.
--  @param state — One of the following:
--      - A WeakMap used to read a private instance field.
--      - A WeakSet used as an instance brand for private instance methods and accessors.
--      - A function value that should be the undecorated class constructor used to brand check private static fields, methods, and accessors.
--  @param kind — (optional pre TS 4.3, required for TS 4.3+) One of the following values:
--      - undefined — Indicates a private instance field (pre TS 4.3).
--      - "f" — Indicates a private field (instance or static).
--      - "m" — Indicates a private method (instance or static).
--      - "a" — Indicates a private accessor (instance or static).
--  @param f — (optional pre TS 4.3) Depends on the arguments for state and kind:
--      - If kind is "m", this should be the function corresponding to the static or instance method.
--      - If kind is "a", this should be the function corresponding to the getter method, or undefined if the getter was not defined.
--      - If kind is "f" and state is a function, this should be an object holding the value of a static field, or undefined if the static field declaration has not yet been evaluated.
-- Usage:
-- This helper will only ever be used by the compiler in the following ways:
--
-- Reading from a private instance field (pre TS 4.3):
--      __classPrivateFieldGet(<any>, <WeakMap>)
--
-- Reading from a private instance field (TS 4.3+):
--      __classPrivateFieldGet(<any>, <WeakMap>, "f")
--
-- Reading from a private instance get accessor (when defined, TS 4.3+):
--      __classPrivateFieldGet(<any>, <WeakSet>, "a", <function>)
--
-- Reading from a private instance get accessor (when not defined, TS 4.3+):
--      __classPrivateFieldGet(<any>, <WeakSet>, "a", void 0)
--      NOTE: This always results in a runtime error.
--
-- Reading from a private instance method (TS 4.3+):
--      __classPrivateFieldGet(<any>, <WeakSet>, "m", <function>)
--
-- Reading from a private static field (TS 4.3+):
--      __classPrivateFieldGet(<any>, <constructor>, "f", <{ value: any }>)
--
-- Reading from a private static get accessor (when defined, TS 4.3+):
--      __classPrivateFieldGet(<any>, <constructor>, "a", <function>)
--
-- Reading from a private static get accessor (when not defined, TS 4.3+):
--      __classPrivateFieldGet(<any>, <constructor>, "a", void 0)
--      NOTE: This always results in a runtime error.
--
-- Reading from a private static method (TS 4.3+):
--      __classPrivateFieldGet(<any>, <constructor>, "m", <function>)
--
printer.classPrivateFieldGetHelper = {
    name = "typescript:classPrivateFieldGet",
    importName = "__classPrivateFieldGet",
    scoped = false,
    text = [[var __classPrivateFieldGet = (this && this.__classPrivateFieldGet) || function (receiver, state, kind, f) {
    if (kind === "a" && !f) throw new TypeError("Private accessor was defined without a getter");
    if (typeof state === "function" ? receiver !== state || !f : !state.has(receiver)) throw new TypeError("Cannot read private member from an object whose class did not declare it");
    return kind === "m" ? f : kind === "a" ? f.call(receiver) : f ? f.value : state.get(receiver);
};]],
}

--
-- Parameters:
--  @param receiver — The object on which the private member will be set.
--  @param state — One of the following:
--      - A WeakMap used to store a private instance field.
--      - A WeakSet used as an instance brand for private instance methods and accessors.
--      - A function value that should be the undecorated class constructor used to brand check private static fields, methods, and accessors.
--  @param value — The value to set.
--  @param kind — (optional pre TS 4.3, required for TS 4.3+) One of the following values:
--       - undefined — Indicates a private instance field (pre TS 4.3).
--       - "f" — Indicates a private field (instance or static).
--       - "m" — Indicates a private method (instance or static).
--       - "a" — Indicates a private accessor (instance or static).
--   @param f — (optional pre TS 4.3) Depends on the arguments for state and kind:
--       - If kind is "m", this should be the function corresponding to the static or instance method.
--       - If kind is "a", this should be the function corresponding to the setter method, or undefined if the setter was not defined.
--       - If kind is "f" and state is a function, this should be an object holding the value of a static field, or undefined if the static field declaration has not yet been evaluated.
-- Usage:
-- This helper will only ever be used by the compiler in the following ways:
--
-- Writing to a private instance field (pre TS 4.3):
--      __classPrivateFieldSet(<any>, <WeakMap>, <any>)
--
-- Writing to a private instance field (TS 4.3+):
--      __classPrivateFieldSet(<any>, <WeakMap>, <any>, "f")
--
-- Writing to a private instance set accessor (when defined, TS 4.3+):
--      __classPrivateFieldSet(<any>, <WeakSet>, <any>, "a", <function>)
--
-- Writing to a private instance set accessor (when not defined, TS 4.3+):
--      __classPrivateFieldSet(<any>, <WeakSet>, <any>, "a", void 0)
--      NOTE: This always results in a runtime error.
--
-- Writing to a private instance method (TS 4.3+):
--      __classPrivateFieldSet(<any>, <WeakSet>, <any>, "m", <function>)
--      NOTE: This always results in a runtime error.
--
-- Writing to a private static field (TS 4.3+):
--      __classPrivateFieldSet(<any>, <constructor>, <any>, "f", <{ value: any }>)
--
-- Writing to a private static set accessor (when defined, TS 4.3+):
--      __classPrivateFieldSet(<any>, <constructor>, <any>, "a", <function>)
--
-- Writing to a private static set accessor (when not defined, TS 4.3+):
--      __classPrivateFieldSet(<any>, <constructor>, <any>, "a", void 0)
--      NOTE: This always results in a runtime error.
--
-- Writing to a private static method (TS 4.3+):
--      __classPrivateFieldSet(<any>, <constructor>, <any>, "m", <function>)
--      NOTE: This always results in a runtime error.
--
printer.classPrivateFieldSetHelper = {
    name = "typescript:classPrivateFieldSet",
    importName = "__classPrivateFieldSet",
    scoped = false,
    text = [[var __classPrivateFieldSet = (this && this.__classPrivateFieldSet) || function (receiver, state, value, kind, f) {
    if (kind === "m") throw new TypeError("Private method is not writable");
    if (kind === "a" && !f) throw new TypeError("Private accessor was defined without a setter");
    if (typeof state === "function" ? receiver !== state || !f : !state.has(receiver)) throw new TypeError("Cannot write private member to an object whose class did not declare it");
    return (kind === "a" ? f.call(receiver, value) : f ? f.value = value : state.set(receiver, value)), value;
};]],
}

--
-- Parameters:
--  @param state — One of the following:
--      - A WeakMap when the member is a private instance field.
--      - A WeakSet when the member is a private instance method or accessor.
--      - A function value that should be the undecorated class constructor when the member is a private static field, method, or accessor.
--  @param receiver — The object being checked if it has the private member.
--
-- Usage:
-- This helper is used to transform `#field in expression` to
--      `__classPrivateFieldIn(<weakMap/weakSet/constructor>, expression)`
--
printer.classPrivateFieldInHelper = {
    name = "typescript:classPrivateFieldIn",
    importName = "__classPrivateFieldIn",
    scoped = false,
    text = [[var __classPrivateFieldIn = (this && this.__classPrivateFieldIn) || function(state, receiver) {
    if (receiver === null || (typeof receiver !== "object" && typeof receiver !== "function")) throw new TypeError("Cannot use 'in' operator on non-object");
    return typeof state === "function" ? receiver === state : state.has(receiver);
};]],
}

-- ES2018 Helpers

printer.awaitHelper = {
    name = "typescript:await",
    importName = "__await",
    scoped = false,
    text = [[var __await = (this && this.__await) || function (v) { return this instanceof __await ? (this.v = v, this) : new __await(v); }]],
}

printer.asyncGeneratorHelper = {
    name = "typescript:asyncGenerator",
    importName = "__asyncGenerator",
    scoped = false,
    dependencies = { printer.awaitHelper },
    text = [[var __asyncGenerator = (this && this.__asyncGenerator) || function (thisArg, _arguments, generator) {
    if (!Symbol.asyncIterator) throw new TypeError("Symbol.asyncIterator is not defined.");
    var g = generator.apply(thisArg, _arguments || []), i, q = [];
    return i = Object.create((typeof AsyncIterator === "function" ? AsyncIterator : Object).prototype), verb("next"), verb("throw"), verb("return", awaitReturn), i[Symbol.asyncIterator] = function () { return this; }, i;
    function awaitReturn(f) { return function (v) { return Promise.resolve(v).then(f, reject); }; }
    function verb(n, f) { if (g[n]) { i[n] = function (v) { return new Promise(function (a, b) { q.push([n, v, a, b]) > 1 || resume(n, v); }); }; if (f) i[n] = f(i[n]); } }
    function resume(n, v) { try { step(g[n](v)); } catch (e) { settle(q[0][3], e); } }
    function step(r) { r.value instanceof __await ? Promise.resolve(r.value.v).then(fulfill, reject) : settle(q[0][2], r); }
    function fulfill(value) { resume("next", value); }
    function reject(value) { resume("throw", value); }
    function settle(f, v) { if (f(v), q.shift(), q.length) resume(q[0][0], q[0][1]); }
};]],
}

printer.asyncDelegatorHelper = {
    name = "typescript:asyncDelegator",
    importName = "__asyncDelegator",
    scoped = false,
    dependencies = { printer.awaitHelper },
    text = [[var __asyncDelegator = (this && this.__asyncDelegator) || function (o) {
    var i, p;
    return i = {}, verb("next"), verb("throw", function (e) { throw e; }), verb("return"), i[Symbol.iterator] = function () { return this; }, i;
    function verb(n, f) { i[n] = o[n] ? function (v) { return (p = !p) ? { value: __await(o[n](v)), done: false } : f ? f(v) : v; } : f; }
};]],
}

printer.asyncValuesHelper = {
    name = "typescript:asyncValues",
    importName = "__asyncValues",
    scoped = false,
    text = [[var __asyncValues = (this && this.__asyncValues) || function (o) {
    if (!Symbol.asyncIterator) throw new TypeError("Symbol.asyncIterator is not defined.");
    var m = o[Symbol.asyncIterator], i;
    return m ? m.call(o) : (o = typeof __values === "function" ? __values(o) : o[Symbol.iterator](), i = {}, verb("next"), verb("throw"), verb("return"), i[Symbol.asyncIterator] = function () { return this; }, i);
    function verb(n) { i[n] = o[n] && function (v) { return new Promise(function (resolve, reject) { v = o[n](v), settle(resolve, reject, v.done, v.value); }); }; }
    function settle(resolve, reject, d, v) { Promise.resolve(v).then(function(v) { resolve({ value: v, done: d }); }, reject); }
};]],
}

-- ES2018 Destructuring Helpers
printer.restHelper = {
    name = "typescript:rest",
    importName = "__rest",
    scoped = false,
    text = [=[var __rest = (this && this.__rest) || function (s, e) {
    var t = {};
    for (var p in s) if (Object.prototype.hasOwnProperty.call(s, p) && e.indexOf(p) < 0)
        t[p] = s[p];
    if (s != null && typeof Object.getOwnPropertySymbols === "function")
        for (var i = 0, p = Object.getOwnPropertySymbols(s); i < p.length; i++) {
            if (e.indexOf(p[i]) < 0 && Object.prototype.propertyIsEnumerable.call(s, p[i]))
                t[p[i]] = s[p[i]];
        }
    return t;
};]=],
}

printer.awaiterHelper = {
    name = "typescript:awaiter",
    importName = "__awaiter",
    scoped = false,
    priority = { value = 5 },
    text = [[var __awaiter = (this && this.__awaiter) || function (thisArg, _arguments, P, generator) {
    function adopt(value) { return value instanceof P ? value : new P(function (resolve) { resolve(value); }); }
    return new (P || (P = Promise))(function (resolve, reject) {
        function fulfilled(value) { try { step(generator.next(value)); } catch (e) { reject(e); } }
        function rejected(value) { try { step(generator["throw"](value)); } catch (e) { reject(e); } }
        function step(result) { result.done ? resolve(result.value) : adopt(result.value).then(fulfilled, rejected); }
        step((generator = generator.apply(thisArg, _arguments || [])).next());
    });
};]],
}

printer.AsyncSuperHelper = {
    name = "typescript:async-super",
    scoped = true,
    textCallback = function(makeUniqueName)
        return "\nconst " .. makeUniqueName("_superIndex") .. " = name => super[name];"
    end,
}

printer.AdvancedAsyncSuperHelper = {
    name = "typescript:advanced-async-super",
    scoped = true,
    textCallback = function(makeUniqueName)
        return "\nconst " .. makeUniqueName("_superIndex") .. " = (function (geti, seti) {\n" .. "    const cache = Object.create(null);\n" .. "    return name => cache[name] || (cache[name] = { get value() { return geti(name); }, set value(v) { seti(name, v); } });\n" .. "})(name => super[name], (name, value) => super[name] = value);"
    end,
}

-- ES Decorator Helpers

printer.esDecorateHelper = {
    name = "typescript:esDecorate",
    importName = "__esDecorate",
    scoped = false,
    priority = { value = 2 },
    text = [[var __esDecorate = (this && this.__esDecorate) || function (ctor, descriptorIn, decorators, contextIn, initializers, extraInitializers) {
    function accept(f) { if (f !== void 0 && typeof f !== "function") throw new TypeError("Function expected"); return f; }
    var kind = contextIn.kind, key = kind === "getter" ? "get" : kind === "setter" ? "set" : "value";
    var target = !descriptorIn && ctor ? contextIn["static"] ? ctor : ctor.prototype : null;
    var descriptor = descriptorIn || (target ? Object.getOwnPropertyDescriptor(target, contextIn.name) : {});
    var _, done = false;
    for (var i = decorators.length - 1; i >= 0; i--) {
        var context = {};
        for (var p in contextIn) context[p] = p === "access" ? {} : contextIn[p];
        for (var p in contextIn.access) context.access[p] = contextIn.access[p];
        context.addInitializer = function (f) { if (done) throw new TypeError("Cannot add initializers after decoration has completed"); extraInitializers.push(accept(f || null)); };
        var result = (0, decorators[i])(kind === "accessor" ? { get: descriptor.get, set: descriptor.set } : descriptor[key], context);
        if (kind === "accessor") {
            if (result === void 0) continue;
            if (result === null || typeof result !== "object") throw new TypeError("Object expected");
            if (_ = accept(result.get)) descriptor.get = _;
            if (_ = accept(result.set)) descriptor.set = _;
            if (_ = accept(result.init)) initializers.unshift(_);
        }
        else if (_ = accept(result)) {
            if (kind === "field") initializers.unshift(_);
            else descriptor[key] = _;
        }
    }
    if (target) Object.defineProperty(target, contextIn.name, descriptor);
    done = true;
};]],
}

printer.runInitializersHelper = {
    name = "typescript:runInitializers",
    importName = "__runInitializers",
    scoped = false,
    priority = { value = 2 },
    text = [[var __runInitializers = (this && this.__runInitializers) || function (thisArg, initializers, value) {
    var useValue = arguments.length > 2;
    for (var i = 0; i < initializers.length; i++) {
        value = useValue ? initializers[i].call(thisArg, value) : initializers[i].call(thisArg);
    }
    return useValue ? value : void 0;
};]],
}

-- ES2015 Helpers

printer.makeTemplateObjectHelper = {
    name = "typescript:makeTemplateObject",
    importName = "__makeTemplateObject",
    scoped = false,
    priority = { value = 0 },
    text = [[var __makeTemplateObject = (this && this.__makeTemplateObject) || function (cooked, raw) {
    if (Object.defineProperty) { Object.defineProperty(cooked, "raw", { value: raw }); } else { cooked.raw = raw; }
    return cooked;
};]],
}

printer.propKeyHelper = {
    name = "typescript:propKey",
    importName = "__propKey",
    scoped = false,
    text = [[var __propKey = (this && this.__propKey) || function (x) {
    return typeof x === "symbol" ? x : "".concat(x);
};]],
}

-- https://tc39.es/ecma262/#sec-setfunctionname
printer.setFunctionNameHelper = {
    name = "typescript:setFunctionName",
    importName = "__setFunctionName",
    scoped = false,
    text = [[var __setFunctionName = (this && this.__setFunctionName) || function (f, name, prefix) {
    if (typeof name === "symbol") name = name.description ? "[".concat(name.description, "]") : "";
    return Object.defineProperty(f, "name", { configurable: true, value: prefix ? "".concat(prefix, " ", name) : name });
};]],
}

-- ES Module Helpers

printer.createBindingHelper = {
    name = "typescript:commonjscreatebinding",
    importName = "__createBinding",
    scoped = false,
    priority = { value = 1 },
    text = [[var __createBinding = (this && this.__createBinding) || (Object.create ? (function(o, m, k, k2) {
    if (k2 === undefined) k2 = k;
    var desc = Object.getOwnPropertyDescriptor(m, k);
    if (!desc || ("get" in desc ? !m.__esModule : desc.writable || desc.configurable)) {
      desc = { enumerable: true, get: function() { return m[k]; } };
    }
    Object.defineProperty(o, k2, desc);
}) : (function(o, m, k, k2) {
    if (k2 === undefined) k2 = k;
    o[k2] = m[k];
}));]],
}

printer.setModuleDefaultHelper = {
    name = "typescript:commonjscreatevalue",
    importName = "__setModuleDefault",
    scoped = false,
    priority = { value = 1 },
    text = [[var __setModuleDefault = (this && this.__setModuleDefault) || (Object.create ? (function(o, v) {
    Object.defineProperty(o, "default", { enumerable: true, value: v });
}) : function(o, v) {
    o["default"] = v;
});]],
}

printer.importStarHelper = {
    name = "typescript:commonjsimportstar",
    importName = "__importStar",
    scoped = false,
    dependencies = { printer.createBindingHelper, printer.setModuleDefaultHelper },
    priority = { value = 2 },
    text = [[var __importStar = (this && this.__importStar) || (function () {
    var ownKeys = function(o) {
        ownKeys = Object.getOwnPropertyNames || function (o) {
            var ar = [];
            for (var k in o) if (Object.prototype.hasOwnProperty.call(o, k)) ar[ar.length] = k;
            return ar;
        };
        return ownKeys(o);
    };
    return function (mod) {
        if (mod && mod.__esModule) return mod;
        var result = {};
        if (mod != null) for (var k = ownKeys(mod), i = 0; i < k.length; i++) if (k[i] !== "default") __createBinding(result, mod, k[i]);
        __setModuleDefault(result, mod);
        return result;
    };
})();]],
}

printer.importDefaultHelper = {
    name = "typescript:commonjsimportdefault",
    importName = "__importDefault",
    scoped = false,
    text = [[var __importDefault = (this && this.__importDefault) || function (mod) {
    return (mod && mod.__esModule) ? mod : { "default": mod };
};]],
}

printer.exportStarHelper = {
    name = "typescript:export-star",
    importName = "__exportStar",
    scoped = false,
    dependencies = { printer.createBindingHelper },
    priority = { value = 2 },
    text = [[var __exportStar = (this && this.__exportStar) || function(m, exports) {
    for (var p in m) if (p !== "default" && !Object.prototype.hasOwnProperty.call(exports, p)) __createBinding(exports, m, p);
};]],
}

printer.rewriteRelativeImportExtensionsHelper = {
    name = "typescript:rewriteRelativeImportExtensions",
    importName = "__rewriteRelativeImportExtension",
    scoped = false,
    text = [[var __rewriteRelativeImportExtension = (this && this.__rewriteRelativeImportExtension) || function (path, preserveJsx) {
    if (typeof path === "string" && /^\.\.?\//.test(path)) {
        return path.replace(/\.(tsx)$|((?:\.d)?)((?:\.[^./]+?)?)\.([cm]?)ts$/i, function (m, tsx, d, ext, cm) {
            return tsx ? preserveJsx ? ".jsx" : ".js" : d && (!ext || !cm) ? m : (d + ext + "." + cm.toLowerCase() + "js");
        });
    }
    return path;
};]],
}
