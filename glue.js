let memory;
let heapEnd = 0n;
const allocations = new Map();
const freeBlocks = [];
const PAGE_SIZE = 64n * 1024n;
const ALIGNMENT = 16n;
const decoder = new TextDecoder();
const encoder = new TextEncoder();
const domNodes = new Map();
const domNodeIds = new WeakMap();
let nextDomId = 1;

function offset(value) {
    const number = Number(value);
    if (!Number.isSafeInteger(number) || number < 0) throw new RangeError("WASM memory offset out of range");
    return number;
}

function ptr(value) {
    return typeof value === "bigint" ? value : BigInt(value);
}

function malloc(size) {
    const requested = ptr(size);
    if (requested <= 0n) return 0n;
    const bytes = (requested + ALIGNMENT - 1n) & ~(ALIGNMENT - 1n);

    const reusable = freeBlocks.findIndex(block => block.size >= bytes);
    if (reusable >= 0) {
        const block = freeBlocks[reusable];
        const result = block.start;
        block.start += bytes;
        block.size -= bytes;
        if (block.size === 0n) freeBlocks.splice(reusable, 1);
        allocations.set(result, bytes);
        return result;
    }

    const start = heapEnd || ptr(memory.buffer.byteLength);
    const pages = (bytes + PAGE_SIZE - 1n) / PAGE_SIZE;
    memory.grow(pages);
    heapEnd = start + pages * PAGE_SIZE;
    const unused = pages * PAGE_SIZE - bytes;
    if (unused) freeBlocks.push({ start: start + bytes, size: unused });
    allocations.set(start, bytes);
    return start;
}

function free(pointer) {
    const start = ptr(pointer);
    const size = allocations.get(start);
    if (start === 0n || size === undefined) return;
    allocations.delete(start);
    freeBlocks.push({ start, size });
    freeBlocks.sort((a, b) => a.start < b.start ? -1 : a.start > b.start ? 1 : 0);
    for (let i = 1; i < freeBlocks.length;) {
        const before = freeBlocks[i - 1];
        const current = freeBlocks[i];
        if (before.start + before.size === current.start) {
            before.size += current.size;
            freeBlocks.splice(i, 1);
        } else i++;
    }
}

function realloc(pointer, newSize) {
    const oldPointer = ptr(pointer);
    const size = ptr(newSize);
    if (oldPointer === 0n) return malloc(size);
    if (size === 0n) {
        free(oldPointer);
        return 0n;
    }
    const oldSize = allocations.get(oldPointer);
    if (oldSize === undefined) throw new Error("realloc received an unknown pointer");
    const alignedSize = (size + ALIGNMENT - 1n) & ~(ALIGNMENT - 1n);
    if (alignedSize <= oldSize) return oldPointer;
    const replacement = malloc(size);
    const copySize = offset(oldSize < size ? oldSize : size);
    new Uint8Array(memory.buffer).copyWithin(offset(replacement), offset(oldPointer), offset(oldPointer) + copySize);
    free(oldPointer);
    return replacement;
}

function view(pointer, length) {
    const start = offset(pointer);
    const size = offset(length);
    if (start + size > memory.buffer.byteLength) throw new RangeError("WASM memory access out of bounds");
    return new Uint8Array(memory.buffer, start, size);
}

function stringAt(pointer, length) {
    return decoder.decode(view(pointer, length));
}

function cStringLength(pointer) {
    const start = offset(pointer);
    const bytes = new Uint8Array(memory.buffer);
    let end = start;
    while (end < bytes.length && bytes[end] !== 0) end++;
    if (end === bytes.length) throw new RangeError("Unterminated C string in WASM memory");
    return end - start;
}

function cString(pointer) {
    return stringAt(pointer, cStringLength(pointer));
}

function memoryCopy(destination, source, length) {
    const dst = offset(destination);
    const src = offset(source);
    const count = offset(length);
    new Uint8Array(memory.buffer).copyWithin(dst, src, src + count);
    return ptr(destination);
}

function memorySet(destination, value, length) {
    const bytes = view(destination, length);
    bytes.fill(Number(value) & 0xff);
    return ptr(destination);
}

function compareBytes(left, right, length) {
    const a = view(left, length);
    const b = view(right, length);
    for (let i = 0; i < a.length; i++) {
        if (a[i] !== b[i]) return a[i] < b[i] ? -1 : 1;
    }
    return 0;
}

function compareStrings(left, right, limit = null) {
    const a = offset(left);
    const b = offset(right);
    const bytes = new Uint8Array(memory.buffer);
    let i = 0;
    while (limit === null || i < limit) {
        const x = bytes[a + i] ?? 0;
        const y = bytes[b + i] ?? 0;
        if (x !== y) return x < y ? -1 : 1;
        if (x === 0) return 0;
        i++;
    }
    return 0;
}

function copyCString(destination, source, limit = null) {
    const dst = offset(destination);
    const src = offset(source);
    const bytes = new Uint8Array(memory.buffer);
    let i = 0;
    while ((limit === null || i < limit) && bytes[src + i] !== 0) {
        bytes[dst + i] = bytes[src + i];
        i++;
    }
    if (limit === null) bytes[dst + i] = 0;
    else while (i < limit) bytes[dst + i++] = 0;
    return ptr(destination);
}

function boundedCStringLength(pointer, maximum) {
    const start = offset(pointer);
    const limit = offset(maximum);
    const bytes = new Uint8Array(memory.buffer);
    let end = 0;
    while (end < limit && bytes[start + end] !== 0) end++;
    return end;
}

function findCStringCharacter(pointer, character) {
    const start = offset(pointer);
    const target = Number(character) & 0xff;
    const bytes = new Uint8Array(memory.buffer);
    for (let i = 0; start + i < bytes.length; i++) {
        if (bytes[start + i] === target) return ptr(start + i);
        if (bytes[start + i] === 0) break;
    }
    return 0n;
}

function node(id) {
    const result = domNodes.get(id);
    if (!result) throw new Error(`Unknown Jai DOM handle ${id}`);
    return result;
}

function registerNode(element) {
    const existing = domNodeIds.get(element);
    if (existing !== undefined) return existing;
    const id = nextDomId++;
    domNodes.set(id, element);
    domNodeIds.set(element, id);
    return id;
}

const imports = {
    env: {
        abort() { throw new WebAssembly.RuntimeError("Jai called abort()"); },
        malloc,
        calloc(count, size) {
            const total = ptr(count) * ptr(size);
            if (total > 0xffffffffffffffffn) return 0n;
            const result = malloc(total);
            if (result !== 0n) memorySet(result, 0, total);
            return result;
        },
        free,
        realloc,
        memcpy: memoryCopy,
        memmove: memoryCopy,
        memset: memorySet,
        memchr(pointer, character, length) {
            const start = offset(pointer);
            const bytes = view(pointer, length);
            const found = bytes.indexOf(Number(character) & 0xff);
            return found < 0 ? 0n : ptr(start + found);
        },
        memcmp: compareBytes,
        strlen(pointer) { return BigInt(cStringLength(pointer)); },
        strnlen(pointer, maximum) { return BigInt(boundedCStringLength(pointer, maximum)); },
        strcmp: compareStrings,
        strncmp(left, right, length) { return compareStrings(left, right, offset(length)); },
        strcpy(destination, source) { return copyCString(destination, source); },
        strncpy(destination, source, length) { return copyCString(destination, source, offset(length)); },
        strcat(destination, source) {
            const end = ptr(destination) + BigInt(cStringLength(destination));
            copyCString(end, source);
            return ptr(destination);
        },
        strncat(destination, source, length) {
            const end = ptr(destination) + BigInt(cStringLength(destination));
            const count = boundedCStringLength(source, length);
            memoryCopy(end, source, BigInt(count));
            memorySet(end + BigInt(count), 0, 1);
            return ptr(destination);
        },
        strchr: findCStringCharacter,
        strrchr(pointer, character) {
            const start = offset(pointer);
            const target = Number(character) & 0xff;
            const bytes = new Uint8Array(memory.buffer);
            let found = target === 0 ? start + cStringLength(pointer) : -1;
            for (let i = 0; start + i < bytes.length; i++) {
                if (bytes[start + i] === target) found = start + i;
                if (bytes[start + i] === 0) break;
            }
            return found < 0 ? 0n : ptr(found);
        },
        strstr(haystack, needle) {
            const start = offset(haystack);
            const textLength = cStringLength(haystack);
            const needleLength = cStringLength(needle);
            if (needleLength === 0) return ptr(haystack);
            const text = view(haystack, textLength);
            const sought = view(needle, needleLength);
            for (let i = 0; i + needleLength <= textLength; i++) {
                let matches = true;
                for (let j = 0; j < needleLength; j++) {
                    if (text[i + j] !== sought[j]) {
                        matches = false;
                        break;
                    }
                }
                if (matches) return ptr(start + i);
            }
            return 0n;
        },
        strdup(source) {
            const length = cStringLength(source);
            const result = malloc(BigInt(length + 1));
            copyCString(result, source);
            return result;
        },
        strndup(source, maximum) {
            const length = boundedCStringLength(source, maximum);
            const result = malloc(BigInt(length + 1));
            memoryCopy(result, source, BigInt(length));
            memorySet(result + BigInt(length), 0, 1);
            return result;
        },
        write(fd, buffer, length) {
            const text = stringAt(buffer, length);
            (fd === 2 ? console.error : console.log)(text);
            return ptr(length);
        },
        puts(pointer) {
            console.log(cString(pointer));
            return 0;
        },
        putchar(character) {
            console.log(String.fromCharCode(Number(character) & 0xff));
            return Number(character) & 0xff;
        },
        exit(status) { throw new WebAssembly.RuntimeError(`Jai exited with status ${status}`); },
        __stack_chk_fail() { throw new WebAssembly.RuntimeError("WASM stack corruption detected"); },
        __assert_fail(assertion, file, line, functionName) {
            throw new WebAssembly.RuntimeError(`${cString(file)}:${line}: assertion failed: ${cString(assertion)} in ${cString(functionName)}`);
        },
        js_dom_find(selector, length) {
            const element = document.querySelector(stringAt(selector, length));
            return element ? registerNode(element) : 0;
        },
        js_dom_find_in(parent, selector, length) {
            const element = node(parent).querySelector(stringAt(selector, length));
            return element ? registerNode(element) : 0;
        },
        js_dom_create(tag, tagLength) {
            return registerNode(document.createElement(stringAt(tag, tagLength)));
        },
        js_dom_insert(parent, child, before) {
            const parentNode = node(parent);
            parentNode.insertBefore(node(child), before === 0 ? null : node(before));
        },
        js_dom_remove(id) {
            const element = domNodes.get(id);
            if (!element || !element.parentNode || element === document.body || element === document.documentElement) return 0;
            element.remove();
            domNodes.delete(id);
            domNodeIds.delete(element);
            return 1;
        },
        js_dom_set_text(id, text, textLength) {
            node(id).textContent = stringAt(text, textLength);
        },
        js_dom_set_attribute(id, name, nameLength, value, valueLength) {
            node(id).setAttribute(stringAt(name, nameLength), stringAt(value, valueLength));
        },
        js_dom_get_attribute(id, name, nameLength, output, capacity) {
            const value = node(id).getAttribute(stringAt(name, nameLength));
            if (value === null) return -1n;
            const bytes = encoder.encode(value);
            const available = offset(capacity);
            if (available < bytes.length) return BigInt(bytes.length);
            view(output, bytes.length).set(bytes);
            return BigInt(bytes.length);
        },
        js_dom_remove_attribute(id, name, nameLength) {
            const element = node(id);
            const key = stringAt(name, nameLength);
            if (!element.hasAttribute(key)) return 0;
            element.removeAttribute(key);
            return 1;
        },
        js_dom_set_style(id, name, nameLength, value, valueLength) {
            const property = stringAt(name, nameLength).replace(/[A-Z]/g, c => `-${c.toLowerCase()}`);
            node(id).style.setProperty(property, stringAt(value, valueLength));
        },
        js_dom_add_event_listener(id, eventName, eventNameLength, callbackIndex) {
            const table = api.__indirect_function_table;
            if (!table) throw new Error("WASM table not exported; cannot invoke Jai event callbacks");
            // In this WASM64 module function-table indices arrive as i64/BigInt.
            const tableIndex = typeof callbackIndex === "bigint" ? callbackIndex : BigInt(callbackIndex);
            const callback = table.get(tableIndex);
            if (typeof callback !== "function") throw new Error("Invalid Jai DOM event callback");
            const event = stringAt(eventName, eventNameLength);
            node(id).addEventListener(event, () => callback(id));
        },
    },
};

const { instance } = await WebAssembly.instantiateStreaming(fetch("./main.wasm"), imports);
const api = instance.exports;
memory = api.memory;
if (!memory) throw new Error("main.wasm does not export memory");

try {
    api.app_init();
} catch (error) {
    console.error("Jai app_init failed:", error);
}
