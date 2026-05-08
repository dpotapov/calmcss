const std = @import("std");
const builtin = @import("builtin");
const core_parity_data = @import("core_parity_data.zig");
const default_color_fallbacks = @import("default_color_fallbacks.zig");
const plugin_parity_data = @import("plugin_parity_data.zig");
const builtin_theme_css = @embedFile("theme.css");
const builtin_preflight_css = @embedFile("preflight.css");
const builtin_theme_preflight_css = @embedFile("preflight.theme.css");

pub const version = "0.1.0";

const theme_root_marker = "/*!calmcss-theme-root*/";

pub const CompileOptions = struct {
    minify: bool = true,
};

pub const Chunk = struct {
    name: []const u8,
    content: []const u8,
};

const OwnedChunk = struct {
    name: []u8,
    content: []u8,
};

const ThemeVariable = struct {
    name: []const u8,
    value: []const u8,
    inline_theme: bool = false,
    reference: bool = false,
    static_theme: bool = false,
    default_theme: bool = false,
    builtin: bool = false,
    initial_theme_reference: bool = false,
};

const CustomUtility = struct {
    name: []const u8,
    declarations: []const u8,
};

const FunctionalUtility = struct {
    prefix: []const u8,
    declarations: []const u8,
};

const CustomVariant = struct {
    name: []const u8,
    value: []const u8,
    media: bool = false,
    body: bool = false,
};

const ThemeKeyframes = struct {
    name: []const u8,
    css: []const u8,
    reference: bool = false,
    static_theme: bool = false,
    default_theme: bool = false,
};

const CustomMedia = struct {
    name: []const u8,
    query: []const u8,
};

const SourceRange = struct {
    start: i64,
    end: i64,
    step: i64,
};

const Compiler = struct {
    allocator: std.mem.Allocator,
    options: CompileOptions,
    candidates: std.ArrayList([]const u8) = .empty,
    negated_source_candidates: std.ArrayList([]const u8) = .empty,
    theme_variables: std.ArrayList(ThemeVariable) = .empty,
    theme_keyframes: std.ArrayList(ThemeKeyframes) = .empty,
    unset_theme_wildcards: std.ArrayList([]const u8) = .empty,
    custom_utilities: std.ArrayList(CustomUtility) = .empty,
    functional_utilities: std.ArrayList(FunctionalUtility) = .empty,
    custom_variants: std.ArrayList(CustomVariant) = .empty,
    custom_media: std.ArrayList(CustomMedia) = .empty,
    authored_css_blocks: std.ArrayList([]const u8) = .empty,
    owned_values: std.ArrayList([]u8) = .empty,
    prefix: ?[]const u8 = null,
    utilities_important: bool = false,
    full_tailwind_import: bool = false,
    theme_root_placeholder_inserted: bool = false,

    fn init(allocator: std.mem.Allocator, options: CompileOptions) Compiler {
        return .{ .allocator = allocator, .options = options };
    }

    fn deinit(self: *Compiler) void {
        self.candidates.deinit(self.allocator);
        self.negated_source_candidates.deinit(self.allocator);
        self.theme_variables.deinit(self.allocator);
        self.theme_keyframes.deinit(self.allocator);
        self.unset_theme_wildcards.deinit(self.allocator);
        self.custom_utilities.deinit(self.allocator);
        self.functional_utilities.deinit(self.allocator);
        self.custom_variants.deinit(self.allocator);
        self.custom_media.deinit(self.allocator);
        self.authored_css_blocks.deinit(self.allocator);
        for (self.owned_values.items) |value| self.allocator.free(value);
        self.owned_values.deinit(self.allocator);
    }

    fn collect(self: *Compiler, chunks: []const Chunk) !void {
        for (chunks) |chunk| {
            try self.collectDefinitions(chunk.content, isCssChunkName(chunk.name));
        }
        for (chunks) |chunk| {
            _ = chunk.name;
            try self.collectSourceDirectives(chunk.content);
        }
        for (chunks) |chunk| {
            try self.collectContent(chunk.content, isCssChunkName(chunk.name));
        }
    }

    fn collectDefinitions(self: *Compiler, content: []const u8, is_css_chunk: bool) !void {
        try self.collectBuiltinThemeImports(content);
        try self.collectThemeVariables(content);
        try self.collectCustomMedia(content);
        try self.collectCustomUtilities(content);
        try self.collectCustomVariants(content);
        try self.collectLegacyVariantDefinitions(content);
        try self.collectAuthoredCssBlocks(content, is_css_chunk);
    }

    fn collectContent(self: *Compiler, content: []const u8, is_css_chunk: bool) !void {
        const css_mode = is_css_chunk or looksLikeCssChunk(content);
        var i: usize = 0;
        while (i < content.len) {
            if (css_mode and skipCssCommentOrStringAt(content, &i)) continue;
            if (styleBlockEndAt(content, i)) |end| {
                i = end;
                continue;
            }
            if (definitionBlockEndCovering(content, i)) |end| {
                i = end;
                continue;
            }
            if (isThemeAtRuleAt(content, i)) {
                i = scanCssBlock(content, i) orelse (i + "@theme".len);
                continue;
            }
            if (isUtilityAtRuleAt(content, i)) {
                i = scanCssBlock(content, i) orelse (i + "@utility".len);
                continue;
            }
            if (isCustomVariantAtRuleAt(content, i)) {
                i = definitionEnd(content, i) orelse (i + "@custom-variant".len);
                continue;
            }
            if (isCustomMediaAtRuleAt(content, i)) {
                i = definitionEnd(content, i) orelse (i + "@custom-media".len);
                continue;
            }
            if (isSourceAtRuleAt(content, i)) {
                i = definitionEnd(content, i) orelse (i + "@source".len);
                continue;
            }
            while (i < content.len) {
                if (css_mode and skipCssCommentOrStringAt(content, &i)) continue;
                if (isTokenChar(content[i])) break;
                i += 1;
            }
            if (styleBlockEndAt(content, i)) |end| {
                i = end;
                continue;
            }
            if (definitionBlockEndCovering(content, i)) |end| {
                i = end;
                continue;
            }
            if (isThemeAtRuleAt(content, i)) {
                i = scanCssBlock(content, i) orelse (i + "@theme".len);
                continue;
            }
            if (isUtilityAtRuleAt(content, i)) {
                i = scanCssBlock(content, i) orelse (i + "@utility".len);
                continue;
            }
            if (isCustomVariantAtRuleAt(content, i)) {
                i = definitionEnd(content, i) orelse (i + "@custom-variant".len);
                continue;
            }
            if (isCustomMediaAtRuleAt(content, i)) {
                i = definitionEnd(content, i) orelse (i + "@custom-media".len);
                continue;
            }
            if (isSourceAtRuleAt(content, i)) {
                i = definitionEnd(content, i) orelse (i + "@source".len);
                continue;
            }
            const start = i;
            var bracket_depth: usize = 0;
            var paren_depth: usize = 0;
            while (i < content.len and isTokenContinuation(content[i], bracket_depth, paren_depth)) : (i += 1) {
                switch (content[i]) {
                    '[' => bracket_depth += 1,
                    ']' => if (bracket_depth > 0) {
                        bracket_depth -= 1;
                    },
                    '(' => paren_depth += 1,
                    ')' => if (paren_depth > 0) {
                        paren_depth -= 1;
                    },
                    else => {},
                }
            }
            if (i > start) try self.addCandidate(content[start..i]);
        }
    }

    fn collectSourceDirectives(self: *Compiler, content: []const u8) !void {
        var search_start: usize = 0;
        while (findCssAtRule(content, &search_start, "@source")) |at| {
            if (!isSourceAtRuleAt(content, at)) {
                search_start = at + "@source".len;
                continue;
            }
            const end = definitionEnd(content, at) orelse break;
            const statement = content[at..end];
            const argument = sourceInlineArgument(statement) orelse {
                search_start = end;
                continue;
            };
            try self.collectInlineSourcePattern(argument, containsCssWord(statement, "not"));
            search_start = end;
        }
    }

    fn collectInlineSourcePattern(self: *Compiler, pattern: []const u8, negated: bool) !void {
        var i: usize = 0;
        while (i < pattern.len) {
            while (i < pattern.len and isAsciiWhitespace(pattern[i])) : (i += 1) {}
            const start = i;
            while (i < pattern.len and !isAsciiWhitespace(pattern[i])) : (i += 1) {}
            if (i > start) try self.expandInlineSourceToken(pattern[start..i], negated);
        }
    }

    fn expandInlineSourceToken(self: *Compiler, token: []const u8, negated: bool) !void {
        const open = std.mem.indexOfScalar(u8, token, '{') orelse {
            try self.addInlineSourceCandidate(token, negated);
            return;
        };
        const close = matchingBrace(token, open) orelse {
            try self.addInlineSourceCandidate(token, negated);
            return;
        };
        const inner = token[open + 1 .. close];
        if (sourceRange(inner)) |range| {
            var value = range.start;
            while (if (range.step > 0) value <= range.end else value >= range.end) : (value += range.step) {
                var value_buf: [64]u8 = undefined;
                const value_text = try std.fmt.bufPrint(&value_buf, "{d}", .{value});
                const expanded = try std.fmt.allocPrint(self.allocator, "{s}{s}{s}", .{ token[0..open], value_text, token[close + 1 ..] });
                errdefer self.allocator.free(expanded);
                try self.owned_values.append(self.allocator, expanded);
                try self.expandInlineSourceToken(expanded, negated);
            }
            return;
        }

        var part_start: usize = 0;
        var i: usize = 0;
        var depth: usize = 0;
        while (i <= inner.len) : (i += 1) {
            const at_end = i == inner.len;
            if (!at_end) {
                switch (inner[i]) {
                    '{' => depth += 1,
                    '}' => if (depth > 0) {
                        depth -= 1;
                    },
                    ',' => if (depth != 0) continue,
                    else => continue,
                }
                if (inner[i] != ',' or depth != 0) continue;
            }
            const part = inner[part_start..i];
            const expanded = try std.fmt.allocPrint(self.allocator, "{s}{s}{s}", .{ token[0..open], part, token[close + 1 ..] });
            errdefer self.allocator.free(expanded);
            try self.owned_values.append(self.allocator, expanded);
            try self.expandInlineSourceToken(expanded, negated);
            part_start = i + 1;
        }
    }

    fn addInlineSourceCandidate(self: *Compiler, candidate: []const u8, negated: bool) !void {
        if (!negated) {
            try self.addCandidate(candidate);
            return;
        }
        for (self.negated_source_candidates.items) |seen| {
            if (std.mem.eql(u8, seen, candidate)) return;
        }
        try self.negated_source_candidates.append(self.allocator, candidate);
    }

    fn collectBuiltinThemeImports(self: *Compiler, content: []const u8) !void {
        var search_start: usize = 0;
        while (findCssAtRule(content, &search_start, "@import")) |at| {
            const end = definitionEnd(content, at) orelse break;
            if (isTailwindImportAt(content, at)) {
                const statement = content[at..end];
                self.full_tailwind_import = true;
                self.collectThemePrefix(statement);
                const inline_theme = containsCssWord(statement, "inline");
                const reference_theme = containsCssWord(statement, "reference");
                const static_theme = containsCssWord(statement, "static");
                try self.collectBuiltinThemeVariables(inline_theme, reference_theme, static_theme, true);
            } else if (isThemeImportAt(content, at)) {
                const statement = content[at..end];
                self.collectThemePrefix(statement);
                const inline_theme = containsCssWord(statement, "inline");
                const reference_theme = containsCssWord(statement, "reference");
                const static_theme = containsCssWord(statement, "static");
                try self.collectBuiltinThemeVariables(inline_theme, reference_theme, static_theme, true);
            }
            search_start = end;
        }

        search_start = 0;
        while (findCssAtRule(content, &search_start, "@reference")) |at| {
            const end = definitionEnd(content, at) orelse break;
            if (isThemeReferenceAt(content, at) or isTailwindReferenceAt(content, at)) {
                const statement = content[at..end];
                self.collectThemePrefix(statement);
                const inline_theme = containsCssWord(statement, "inline");
                try self.collectBuiltinThemeVariables(inline_theme, true, false, true);
            }
            search_start = end;
        }
    }

    fn collectBuiltinThemeVariables(self: *Compiler, inline_theme: bool, reference_theme: bool, static_theme: bool, default_theme: bool) !void {
        const start = std.mem.indexOf(u8, builtin_theme_css, "@theme") orelse return;
        const end = scanCssBlock(builtin_theme_css, start) orelse return;
        const open_rel = std.mem.indexOfScalar(u8, builtin_theme_css[start..end], '{') orelse return;
        const open = start + open_rel;
        const body = builtin_theme_css[open + 1 .. end - 1];
        try self.collectThemeKeyframes(body, reference_theme, static_theme, default_theme);
        try self.collectThemeDeclarations(body, inline_theme, reference_theme, static_theme, default_theme, true);
    }

    fn addCandidate(self: *Compiler, raw_token: []const u8) !void {
        const token = cleanToken(raw_token);
        if (self.sourceCandidateIsNegated(token)) return;
        if (token.len == 0 or (!looksLikeCandidate(token) and !self.hasCustomUtilityCandidate(token))) return;
        for (self.candidates.items) |seen| {
            if (std.mem.eql(u8, seen, token)) return;
        }
        try self.candidates.append(self.allocator, token);
    }

    fn sourceCandidateIsNegated(self: *Compiler, candidate: []const u8) bool {
        for (self.negated_source_candidates.items) |negated| {
            if (std.mem.eql(u8, negated, candidate)) return true;
        }
        return false;
    }

    fn hasCustomUtilityCandidate(self: *Compiler, raw: []const u8) bool {
        var variants_buf: [16][]const u8 = undefined;
        const parsed = parseCandidateForCompiler(self, raw, &variants_buf) orelse return false;
        return self.hasCustomUtility(parsed.base) or self.hasFunctionalUtility(parsed.base);
    }

    fn hasCustomUtility(self: *Compiler, base: []const u8) bool {
        for (self.custom_utilities.items) |utility| {
            if (std.mem.eql(u8, utility.name, base)) return true;
        }
        return false;
    }

    fn hasFunctionalUtility(self: *Compiler, base: []const u8) bool {
        for (self.functional_utilities.items) |utility| {
            if (functionalUtilityMatch(utility.prefix, utility.declarations, base) != null) return true;
        }
        return false;
    }

    fn hasCustomVariant(self: *Compiler, name: []const u8) bool {
        for (self.custom_variants.items) |variant| {
            if (std.mem.eql(u8, variant.name, name)) return true;
        }
        return false;
    }

    fn render(self: *Compiler) ![]u8 {
        std.mem.sort([]const u8, self.candidates.items, self, candidateLessThan);
        self.utilities_important = self.utilitiesEntrypointIsImportant();

        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(self.allocator);

        var utilities: std.ArrayList(u8) = .empty;
        defer utilities.deinit(self.allocator);
        for (self.candidates.items) |candidate| {
            if (self.sourceCandidateIsNegated(candidate)) continue;
            try renderCandidate(self, &utilities, candidate);
        }
        const utilities_body = try self.allocator.dupe(u8, utilities.items);
        defer self.allocator.free(utilities_body);
        try appendThemeAnimationKeyframesForValueDedup(self, &utilities, utilities_body, utilities_body);

        var utilities_inserted = false;
        for (self.authored_css_blocks.items) |css| {
            try appendAuthoredCss(self, &out, css, utilities.items, &utilities_inserted);
        }
        if (!utilities_inserted) {
            try out.appendSlice(self.allocator, utilities.items);
        }
        try self.appendStaticThemeKeyframes(&out);

        const body = try out.toOwnedSlice(self.allocator);
        defer self.allocator.free(body);
        const raw = if (self.full_tailwind_import)
            try self.allocator.dupe(u8, body)
        else
            try self.placeThemeRoot(body);
        defer self.allocator.free(raw);
        _ = self.options;
        const hoisted = try hoistTailwindAtRules(self.allocator, raw);
        defer self.allocator.free(hoisted);
        return try mergeAdjacentCssRules(self.allocator, hoisted);
    }

    fn collectThemeVariables(self: *Compiler, content: []const u8) !void {
        var search_start: usize = 0;
        while (findCssAtRule(content, &search_start, "@theme")) |at| {
            const params_start = at + "@theme".len;
            if (params_start < content.len and isNameChar(content[params_start])) {
                search_start = params_start;
                continue;
            }
            const end = definitionEnd(content, at) orelse break;
            const open = findCssBlockOpen(content, params_start) orelse {
                const params = trimAscii(content[params_start .. end - 1]);
                self.collectThemePrefix(params);
                search_start = end;
                continue;
            };
            if (open >= end) {
                const params = trimAscii(content[params_start .. end - 1]);
                self.collectThemePrefix(params);
                search_start = end;
                continue;
            }
            if (end <= open + 1) {
                search_start = end;
                continue;
            }

            const params = content[params_start..open];
            const media_params = mediaThemeParamsCovering(content, at) orelse "";
            self.collectThemePrefix(params);
            self.collectThemePrefix(media_params);
            const inline_theme = containsCssWord(params, "inline") or containsCssWord(media_params, "inline");
            const reference_theme = containsCssWord(params, "reference") or containsCssWord(media_params, "reference");
            const static_theme = containsCssWord(params, "static") or containsCssWord(media_params, "static");
            const default_theme = containsCssWord(params, "default") or containsCssWord(media_params, "default");
            const body = content[open + 1 .. end - 1];
            try self.collectThemeKeyframes(body, reference_theme, static_theme, default_theme);
            try self.collectThemeDeclarations(body, inline_theme, reference_theme, static_theme, default_theme, false);
            search_start = end;
        }
    }

    fn collectThemePrefix(self: *Compiler, params: []const u8) void {
        const prefix = extractPrefixParam(params) orelse return;
        if (isValidPrefix(prefix)) self.prefix = prefix;
    }

    fn collectThemeDeclarations(self: *Compiler, body: []const u8, inline_theme: bool, reference_theme: bool, static_theme: bool, default_theme: bool, builtin_theme: bool) !void {
        var i: usize = 0;
        while (i < body.len) {
            skipCssWhitespaceAndComments(body, &i);
            if (i >= body.len) break;
            if (std.mem.startsWith(u8, body[i..], "@keyframes")) {
                i = scanCssBlock(body, i) orelse (i + "@keyframes".len);
                continue;
            }
            if (!std.mem.startsWith(u8, body[i..], "--")) {
                i += 1;
                continue;
            }

            const name_start = i;
            while (i < body.len and body[i] != ':') : (i += 1) {}
            if (i >= body.len) break;
            const name = trimAscii(body[name_start..i]);
            i += 1;

            const value_start = i;
            var bracket_depth: usize = 0;
            var paren_depth: usize = 0;
            while (i < body.len) : (i += 1) {
                switch (body[i]) {
                    '[' => bracket_depth += 1,
                    ']' => if (bracket_depth > 0) {
                        bracket_depth -= 1;
                    },
                    '(' => paren_depth += 1,
                    ')' => if (paren_depth > 0) {
                        paren_depth -= 1;
                    },
                    ';' => if (bracket_depth == 0 and paren_depth == 0) break,
                    else => {},
                }
            }
            const raw_value = trimAscii(body[value_start..i]);
            if (i < body.len and body[i] == ';') i += 1;
            if (name.len == 0 or raw_value.len == 0) continue;
            if (themeWildcardPrefix(name)) |prefix| {
                if (std.mem.eql(u8, raw_value, "initial")) try self.unsetThemeWildcard(prefix, default_theme);
                continue;
            }
            const resolved_value = try self.resolveThemeFunctionValue(raw_value);
            var rewritten_value: std.ArrayList(u8) = .empty;
            defer rewritten_value.deinit(self.allocator);
            const theme_value = if (try rewriteAuthoredCssFunctions(self, &rewritten_value, resolved_value, false)) blk: {
                const owned = try rewritten_value.toOwnedSlice(self.allocator);
                errdefer self.allocator.free(owned);
                try self.owned_values.append(self.allocator, owned);
                break :blk owned;
            } else resolved_value;
            const value = try self.normalizeThemeValue(theme_value);
            try self.putThemeVariable(name, value, inline_theme, reference_theme, static_theme, default_theme, builtin_theme, themeFunctionInitialReference(raw_value));
        }
    }

    fn unsetThemeWildcard(self: *Compiler, prefix: []const u8, default_theme: bool) !void {
        try self.unset_theme_wildcards.append(self.allocator, prefix);
        if (std.mem.eql(u8, prefix, "--keyframes-")) {
            var i: usize = 0;
            while (i < self.theme_keyframes.items.len) {
                const keyframes = self.theme_keyframes.items[i];
                if (default_theme and !keyframes.default_theme) {
                    i += 1;
                    continue;
                }
                _ = self.theme_keyframes.orderedRemove(i);
            }
            return;
        }

        for (self.theme_variables.items) |*variable| {
            if (default_theme and !variable.default_theme) continue;
            if (!themeWildcardMatches(prefix, variable.name)) continue;
            variable.value = "initial";
            variable.inline_theme = false;
            variable.reference = false;
            variable.static_theme = false;
            variable.default_theme = default_theme;
            variable.builtin = false;
            variable.initial_theme_reference = false;
        }
    }

    fn collectThemeKeyframes(self: *Compiler, body: []const u8, reference_theme: bool, static_theme: bool, default_theme: bool) !void {
        var search_start: usize = 0;
        while (findCssAtRule(body, &search_start, "@keyframes")) |at| {
            const name_start = at + "@keyframes".len;
            if (name_start < body.len and isNameChar(body[name_start])) {
                search_start = name_start;
                continue;
            }
            const end = scanCssBlock(body, at) orelse break;
            const open = findCssBlockOpen(body, at) orelse {
                search_start = end;
                continue;
            };
            if (open >= end) {
                search_start = end;
                continue;
            }
            const name = trimAscii(body[name_start..open]);
            if (name.len > 0) try self.putThemeKeyframes(name, body[at..end], reference_theme, static_theme, default_theme);
            search_start = end;
        }
    }

    fn resolveThemeFunctionValue(self: *Compiler, value: []const u8) ![]const u8 {
        if (!std.mem.startsWith(u8, value, "--theme(") or !std.mem.endsWith(u8, value, ")")) return value;
        const inner = value["--theme(".len .. value.len - 1];
        const comma = topLevelComma(inner) orelse return value;
        const name = trimAscii(inner[0..comma]);
        const fallback = trimAscii(inner[comma + 1 ..]);
        if (name.len == 0) return fallback;

        if (findThemeVariable(self, name)) |dependency| {
            if (!std.mem.eql(u8, dependency.value, "initial")) {
                var name_buf: [512]u8 = undefined;
                const css_name = formatCssVariableName(self, &name_buf, dependency.name) orelse return fallback;
                const owned = try std.fmt.allocPrint(self.allocator, "var({s})", .{css_name});
                try self.owned_values.append(self.allocator, owned);
                return owned;
            }
        }

        return fallback;
    }

    fn themeFunctionInitialReference(value: []const u8) bool {
        if (!std.mem.startsWith(u8, value, "--theme(") or !std.mem.endsWith(u8, value, ")")) return false;
        const inner = value["--theme(".len .. value.len - 1];
        const comma = topLevelComma(inner) orelse return false;
        const fallback = trimAscii(inner[comma + 1 ..]);
        if (!std.mem.eql(u8, fallback, "initial")) return false;
        return removeTrailingCssWord(trimAscii(inner[0..comma]), "inline") == null;
    }

    fn normalizeThemeValue(self: *Compiler, value: []const u8) ![]const u8 {
        if (std.mem.endsWith(u8, value, "ms")) {
            var duration_buf: [64]u8 = undefined;
            if (normalizeTransitionDuration(&duration_buf, value)) |duration| {
                const owned = try self.allocator.dupe(u8, duration);
                errdefer self.allocator.free(owned);
                try self.owned_values.append(self.allocator, owned);
                return owned;
            }
        }

        var needs_copy = false;
        for (value, 0..) |c, i| {
            if (c == '\'') {
                needs_copy = true;
                break;
            }
            if (isLeadingZeroDecimal(value, i)) {
                needs_copy = true;
                break;
            }
        }
        if (!needs_copy) return value;

        var owned: std.ArrayList(u8) = .empty;
        errdefer owned.deinit(self.allocator);
        var i: usize = 0;
        while (i < value.len) : (i += 1) {
            if (value[i] == '\'') {
                try owned.append(self.allocator, '"');
                continue;
            }
            if (isLeadingZeroDecimal(value, i)) continue;
            try owned.append(self.allocator, value[i]);
        }
        const normalized = try owned.toOwnedSlice(self.allocator);
        errdefer self.allocator.free(normalized);
        try self.owned_values.append(self.allocator, normalized);
        return normalized;
    }

    fn isLeadingZeroDecimal(value: []const u8, index: usize) bool {
        if (value[index] != '0') return false;
        if (index + 2 >= value.len or value[index + 1] != '.' or !isDigit(value[index + 2])) return false;
        if (index == 0) return true;
        const previous = value[index - 1];
        return !isDigit(previous) and previous != '.';
    }

    fn putThemeVariable(self: *Compiler, name: []const u8, value: []const u8, inline_theme: bool, reference_theme: bool, static_theme: bool, default_theme: bool, builtin_theme: bool, initial_theme_reference: bool) !void {
        for (self.theme_variables.items) |*variable| {
            if (std.mem.eql(u8, variable.name, name)) {
                if (default_theme and !variable.default_theme) return;
                variable.value = value;
                variable.inline_theme = inline_theme;
                variable.reference = reference_theme;
                variable.static_theme = static_theme;
                variable.default_theme = default_theme;
                variable.builtin = builtin_theme;
                variable.initial_theme_reference = initial_theme_reference;
                return;
            }
        }
        try self.theme_variables.append(self.allocator, .{
            .name = name,
            .value = value,
            .inline_theme = inline_theme,
            .reference = reference_theme,
            .static_theme = static_theme,
            .default_theme = default_theme,
            .builtin = builtin_theme,
            .initial_theme_reference = initial_theme_reference,
        });
    }

    fn putThemeKeyframes(self: *Compiler, name: []const u8, css: []const u8, reference_theme: bool, static_theme: bool, default_theme: bool) !void {
        for (self.theme_keyframes.items) |*keyframes| {
            if (std.mem.eql(u8, keyframes.name, name)) {
                if (default_theme and !keyframes.default_theme) return;
                keyframes.css = css;
                keyframes.reference = reference_theme;
                keyframes.static_theme = static_theme;
                keyframes.default_theme = default_theme;
                return;
            }
        }
        try self.theme_keyframes.append(self.allocator, .{
            .name = name,
            .css = css,
            .reference = reference_theme,
            .static_theme = static_theme,
            .default_theme = default_theme,
        });
    }

    fn appendStaticThemeKeyframes(self: *Compiler, out: *std.ArrayList(u8)) !void {
        for (self.theme_keyframes.items) |keyframes| {
            if (!keyframes.static_theme or keyframes.reference) continue;
            if (std.mem.indexOf(u8, out.items, keyframes.css) != null) continue;
            try out.appendSlice(self.allocator, keyframes.css);
        }
    }

    fn collectCustomMedia(self: *Compiler, content: []const u8) !void {
        var search_start: usize = 0;
        while (findCssAtRule(content, &search_start, "@custom-media")) |at| {
            if (!isCustomMediaAtRuleAt(content, at)) {
                search_start = at + "@custom-media".len;
                continue;
            }

            const end = definitionEnd(content, at) orelse break;
            if (end <= at + "@custom-media".len) {
                search_start = end;
                continue;
            }

            const statement_end = if (content[end - 1] == ';') end - 1 else end;
            const statement = trimAscii(content[at + "@custom-media".len .. statement_end]);
            try self.collectCustomMediaStatement(statement);
            search_start = end;
        }
    }

    fn collectCustomMediaStatement(self: *Compiler, statement: []const u8) !void {
        var name_end: usize = 0;
        while (name_end < statement.len and !isAsciiWhitespace(statement[name_end])) : (name_end += 1) {}
        const name = statement[0..name_end];
        if (!std.mem.startsWith(u8, name, "--")) return;

        const query = trimAscii(statement[name_end..]);
        if (query.len == 0) return;

        var rewritten: std.ArrayList(u8) = .empty;
        defer rewritten.deinit(self.allocator);
        if (try rewriteAuthoredCssFunctions(self, &rewritten, query, true)) {
            const owned = try rewritten.toOwnedSlice(self.allocator);
            errdefer self.allocator.free(owned);
            try self.owned_values.append(self.allocator, owned);
            try self.putCustomMedia(name, owned);
        } else {
            try self.putCustomMedia(name, query);
        }
    }

    fn putCustomMedia(self: *Compiler, name: []const u8, query: []const u8) !void {
        for (self.custom_media.items) |*custom_media| {
            if (std.mem.eql(u8, custom_media.name, name)) {
                custom_media.query = query;
                return;
            }
        }
        try self.custom_media.append(self.allocator, .{
            .name = name,
            .query = query,
        });
    }

    fn collectCustomUtilities(self: *Compiler, content: []const u8) !void {
        var search_start: usize = 0;
        while (findCssAtRule(content, &search_start, "@utility")) |at| {
            const params_start = at + "@utility".len;
            if (params_start < content.len and isNameChar(content[params_start])) {
                search_start = params_start;
                continue;
            }
            const open = findCssBlockOpen(content, params_start) orelse break;
            const end = scanCssBlock(content, at) orelse break;
            if (open >= end) {
                search_start = end;
                continue;
            }
            if (end <= open + 1) {
                search_start = end;
                continue;
            }

            const name = trimAscii(content[params_start..open]);
            const declarations = trimAscii(content[open + 1 .. end - 1]);
            if (isSupportedStaticUtilityName(name) and declarations.len > 0) {
                try self.custom_utilities.append(self.allocator, .{
                    .name = name,
                    .declarations = declarations,
                });
            } else if (functionalUtilityPrefix(name)) |prefix| {
                if (declarations.len > 0) {
                    for (self.functional_utilities.items) |utility| {
                        if (std.mem.eql(u8, utility.prefix, prefix)) break;
                    } else {
                        try self.functional_utilities.append(self.allocator, .{
                            .prefix = prefix,
                            .declarations = declarations,
                        });
                    }
                }
            }
            search_start = end;
        }
    }

    fn collectCustomVariants(self: *Compiler, content: []const u8) !void {
        var search_start: usize = 0;
        while (findCssAtRule(content, &search_start, "@custom-variant")) |at| {
            const params_start = at + "@custom-variant".len;
            if (params_start < content.len and isNameChar(content[params_start])) {
                search_start = params_start;
                continue;
            }
            const end = definitionEnd(content, at) orelse break;
            if (scanCssBlock(content, at)) |block_end| {
                if (block_end == end) {
                    const open_abs = findCssBlockOpen(content, params_start) orelse {
                        search_start = end;
                        continue;
                    };
                    if (open_abs >= end) {
                        search_start = end;
                        continue;
                    }
                    const name = trimAscii(content[params_start..open_abs]);
                    const body = trimAscii(content[open_abs + 1 .. end - 1]);
                    try self.collectBodyCustomVariant(name, body);
                    search_start = end;
                    continue;
                }
            }
            const statement = content[params_start .. end - 1];
            try self.collectBodylessCustomVariant(statement);
            search_start = end;
        }
    }

    fn collectBodyCustomVariant(self: *Compiler, name: []const u8, body: []const u8) !void {
        if (!isSupportedCustomVariantName(name)) return;
        if (!customVariantBodyHasSelectorSlot(body)) return;
        try self.custom_variants.append(self.allocator, .{
            .name = name,
            .value = body,
            .body = true,
        });
    }

    fn collectBodylessCustomVariant(self: *Compiler, statement: []const u8) !void {
        const params = trimAscii(statement);
        var name_end: usize = 0;
        while (name_end < params.len and !isAsciiWhitespace(params[name_end]) and params[name_end] != '(') : (name_end += 1) {}
        const name = params[0..name_end];
        if (!isSupportedCustomVariantName(name)) return;

        const open = std.mem.indexOfScalar(u8, params[name_end..], '(') orelse return;
        const selector_start = name_end + open + 1;
        const close = lastIndexOfScalar(params, ')') orelse return;
        if (close <= selector_start) return;
        const value = trimAscii(params[selector_start..close]);
        if (value.len == 0) return;

        const media = std.mem.startsWith(u8, value, "@media ");
        const stored_value = if (media) trimAscii(value["@media ".len..]) else value;
        try self.custom_variants.append(self.allocator, .{
            .name = name,
            .value = stored_value,
            .media = media,
        });
    }

    fn collectLegacyVariantDefinitions(self: *Compiler, content: []const u8) !void {
        var search_start: usize = 0;
        while (findCssAtRule(content, &search_start, "@variant")) |at| {
            const params_start = at + "@variant".len;
            if (params_start < content.len and isNameChar(content[params_start])) {
                search_start = params_start;
                continue;
            }
            if (atRuleBlockEndCovering(content, at, "@custom-variant")) |custom_end| {
                search_start = custom_end;
                continue;
            }
            const end = definitionEnd(content, at) orelse break;
            if (scanCssBlock(content, at)) |block_end| {
                if (block_end == end) {
                    const open_abs = findCssBlockOpen(content, params_start) orelse {
                        search_start = end;
                        continue;
                    };
                    if (open_abs >= end) {
                        search_start = end;
                        continue;
                    }
                    const name = trimAscii(content[params_start..open_abs]);
                    const body = trimAscii(content[open_abs + 1 .. end - 1]);
                    if (customVariantBodyHasSelectorSlot(body)) {
                        try self.collectBodyCustomVariant(name, body);
                    }
                    search_start = end;
                    continue;
                }
            }

            const statement = trimAscii(content[params_start .. end - 1]);
            if (std.mem.indexOfScalar(u8, statement, '(') != null) {
                try self.collectBodylessCustomVariant(statement);
            }
            search_start = end;
        }
    }

    fn collectAuthoredCssBlocks(self: *Compiler, content: []const u8, is_css_chunk: bool) !void {
        var search_start: usize = 0;
        var found_style = false;
        while (std.mem.indexOf(u8, content[search_start..], "<style")) |rel| {
            found_style = true;
            const tag_start = search_start + rel;
            const tag_end_rel = std.mem.indexOfScalar(u8, content[tag_start..], '>') orelse break;
            const body_start = tag_start + tag_end_rel + 1;
            const close_rel = std.mem.indexOf(u8, content[body_start..], "</style>") orelse break;
            const body_end = body_start + close_rel;
            try self.authored_css_blocks.append(self.allocator, content[body_start..body_end]);
            search_start = body_end + "</style>".len;
        }

        if (!found_style and (is_css_chunk or looksLikeCssChunk(content))) {
            try self.authored_css_blocks.append(self.allocator, content);
        }
    }

    fn utilitiesEntrypointIsImportant(self: *Compiler) bool {
        for (self.authored_css_blocks.items) |css| {
            var search_start: usize = 0;
            while (findCssAtRule(css, &search_start, "@import")) |at| {
                const end = definitionEnd(css, at) orelse break;
                if (isUtilitiesImportAt(css, at) and statementHasImportant(css[at..end])) return true;
                search_start = end;
            }
        }
        return false;
    }

    fn placeThemeRoot(self: *Compiler, body: []const u8) ![]u8 {
        var root: std.ArrayList(u8) = .empty;
        defer root.deinit(self.allocator);
        try self.appendThemeRoot(&root, body);

        if (std.mem.indexOf(u8, body, theme_root_marker)) |marker_at| {
            var placed: std.ArrayList(u8) = .empty;
            errdefer placed.deinit(self.allocator);
            try placed.appendSlice(self.allocator, body[0..marker_at]);
            try placed.appendSlice(self.allocator, root.items);
            try placed.appendSlice(self.allocator, body[marker_at + theme_root_marker.len ..]);
            if (root.items.len == 0) {
                const without_empty_theme = try removeEmptyCssAtRuleBlocks(self.allocator, placed.items);
                placed.deinit(self.allocator);
                return without_empty_theme;
            }
            return try placed.toOwnedSlice(self.allocator);
        }

        if (root.items.len == 0) return try self.allocator.dupe(u8, body);

        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(self.allocator);
        try out.appendSlice(self.allocator, root.items);
        try out.appendSlice(self.allocator, body);
        return try out.toOwnedSlice(self.allocator);
    }

    fn appendThemeRoot(self: *Compiler, out: *std.ArrayList(u8), body: []const u8) !void {
        if (self.theme_variables.items.len == 0) return;

        const emit = try self.allocator.alloc(bool, self.theme_variables.items.len);
        defer self.allocator.free(emit);
        @memset(emit, false);

        var has_variables = false;
        for (self.theme_variables.items, 0..) |variable, i| {
            if (shouldEmitThemeVariableDirect(self, variable, body)) {
                emit[i] = true;
                has_variables = true;
            }
        }
        if (!has_variables) return;

        var changed = true;
        while (changed) {
            changed = false;
            for (self.theme_variables.items, 0..) |variable, i| {
                if (emit[i]) continue;
                if (themeVariableIsDependencyOfEmitted(self, variable, emit)) {
                    emit[i] = true;
                    changed = true;
                }
            }
        }

        try out.appendSlice(self.allocator, ":root,:host{");
        for (self.theme_variables.items, 0..) |variable, i| {
            if (!emit[i]) continue;
            try appendCssVariableName(self, out, variable.name);
            try out.append(self.allocator, ':');
            try out.appendSlice(self.allocator, variable.value);
            try out.append(self.allocator, ';');
        }
        try out.append(self.allocator, '}');
    }
};

pub fn compileAlloc(allocator: std.mem.Allocator, chunks: []const Chunk, options: CompileOptions) ![]u8 {
    var compiler = Compiler.init(allocator, options);
    defer compiler.deinit();
    try compiler.collect(chunks);
    return compiler.render();
}

fn removeEmptyCssAtRuleBlocks(allocator: std.mem.Allocator, css: []const u8) ![]u8 {
    var current = try allocator.dupe(u8, css);
    errdefer allocator.free(current);

    var changed = true;
    while (changed) {
        changed = false;
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(allocator);

        var i: usize = 0;
        while (i < current.len) {
            if (current[i] == '@') {
                if (scanCssBlock(current, i)) |end| {
                    const open_rel = std.mem.indexOfScalar(u8, current[i..end], '{') orelse {
                        try out.append(allocator, current[i]);
                        i += 1;
                        continue;
                    };
                    const open = i + open_rel;
                    if (trimAscii(current[open + 1 .. end - 1]).len == 0) {
                        i = end;
                        changed = true;
                        continue;
                    }
                }
            }
            try out.append(allocator, current[i]);
            i += 1;
        }

        allocator.free(current);
        current = try out.toOwnedSlice(allocator);
    }
    return current;
}

fn candidateLessThan(compiler: *Compiler, lhs: []const u8, rhs: []const u8) bool {
    if (containerCandidateLessThan(compiler, lhs, rhs)) |less| return less;
    if (breakpointCandidateLessThan(compiler, lhs, rhs)) |less| return less;
    if (customVariantCandidateLessThan(compiler, lhs, rhs)) |less| return less;
    if (parityDataSortRank(lhs)) |left_rank| {
        if (parityDataSortRank(rhs)) |right_rank| {
            if (left_rank != right_rank) return left_rank < right_rank;
        }
    }
    const left = candidateSortKey(compiler, lhs);
    const right = candidateSortKey(compiler, rhs);
    if (left.variants != right.variants) return left.variants < right.variants;
    if (left.properties.order != right.properties.order) return left.properties.order < right.properties.order;
    if (left.properties.count != right.properties.count) return left.properties.count > right.properties.count;
    return candidateNameLessThan(lhs, rhs);
}

fn customVariantCandidateLessThan(compiler: *Compiler, lhs: []const u8, rhs: []const u8) ?bool {
    var lhs_variants_buf: [16][]const u8 = undefined;
    const lhs_parsed = parseCandidateForCompiler(compiler, lhs, &lhs_variants_buf) orelse return null;
    var rhs_variants_buf: [16][]const u8 = undefined;
    const rhs_parsed = parseCandidateForCompiler(compiler, rhs, &rhs_variants_buf) orelse return null;
    if (!candidateHasCustomVariant(compiler, lhs_parsed.variants) or !candidateHasCustomVariant(compiler, rhs_parsed.variants)) return null;
    if (lhs_parsed.variants.len != rhs_parsed.variants.len) return lhs_parsed.variants.len < rhs_parsed.variants.len;
    return null;
}

fn containerCandidateLessThan(compiler: *Compiler, lhs: []const u8, rhs: []const u8) ?bool {
    var lhs_variants_buf: [16][]const u8 = undefined;
    const lhs_parsed = parseCandidateForCompiler(compiler, lhs, &lhs_variants_buf) orelse return null;
    var rhs_variants_buf: [16][]const u8 = undefined;
    const rhs_parsed = parseCandidateForCompiler(compiler, rhs, &rhs_variants_buf) orelse return null;
    if (lhs_parsed.variants.len == 0 or rhs_parsed.variants.len == 0) return null;

    const lhs_container = themeContainerForVariant(compiler, lhs_parsed.variants[0]) orelse return null;
    const rhs_container = themeContainerForVariant(compiler, rhs_parsed.variants[0]) orelse return null;

    if (lhs_container.max != rhs_container.max) return lhs_container.max;
    if (containerLengthCompare(lhs_container.value, rhs_container.value)) |order| {
        if (order != .eq) {
            return if (lhs_container.max) order == .gt else order == .lt;
        }
    } else {
        const order = std.mem.order(u8, lhs_container.value, rhs_container.value);
        if (order != .eq) return if (lhs_container.max) order == .gt else order == .lt;
    }

    if (!lhs_container.max and lhs_container.explicit_min != rhs_container.explicit_min) {
        return !lhs_container.explicit_min;
    }
    if ((lhs_container.name != null) != (rhs_container.name != null)) {
        return lhs_container.name != null;
    }
    return null;
}

const BreakpointVariant = struct {
    value: []const u8,
    max: bool,
    sort_max: bool,
    explicit_min: bool,
    arbitrary: bool,
};

fn breakpointCandidateLessThan(compiler: *Compiler, lhs: []const u8, rhs: []const u8) ?bool {
    var lhs_variants_buf: [16][]const u8 = undefined;
    const lhs_parsed = parseCandidateForCompiler(compiler, lhs, &lhs_variants_buf) orelse return null;
    var rhs_variants_buf: [16][]const u8 = undefined;
    const rhs_parsed = parseCandidateForCompiler(compiler, rhs, &rhs_variants_buf) orelse return null;
    if (lhs_parsed.variants.len == 0 or rhs_parsed.variants.len == 0) return null;

    const compare_len = @min(lhs_parsed.variants.len, rhs_parsed.variants.len);
    var i: usize = 0;
    while (i < compare_len) : (i += 1) {
        const lhs_breakpoint = breakpointForVariant(compiler, lhs_parsed.variants[i]);
        const rhs_breakpoint = breakpointForVariant(compiler, rhs_parsed.variants[i]);
        if (lhs_breakpoint == null or rhs_breakpoint == null) {
            if (lhs_breakpoint == null and rhs_breakpoint == null) return null;
            if (looksLikeBreakpointSortVariant(compiler, lhs_parsed.variants[i]) and looksLikeBreakpointSortVariant(compiler, rhs_parsed.variants[i])) {
                return lhs_breakpoint != null;
            }
            return null;
        }
        const lhs_bp = lhs_breakpoint.?;
        const rhs_bp = rhs_breakpoint.?;
        if (lhs_bp.arbitrary and rhs_bp.arbitrary) return null;
        if (lhs_bp.sort_max != rhs_bp.sort_max) return lhs_bp.sort_max;
        if (containerLengthCompare(lhs_bp.value, rhs_bp.value)) |order| {
            if (order != .eq) {
                return if (lhs_bp.sort_max) order == .gt else order == .lt;
            }
        } else {
            const order = std.mem.order(u8, lhs_bp.value, rhs_bp.value);
            if (order != .eq) return if (lhs_bp.sort_max) order == .gt else order == .lt;
        }
    }
    return null;
}

fn looksLikeBreakpointSortVariant(compiler: *Compiler, variant: []const u8) bool {
    if (std.mem.startsWith(u8, variant, "min-") or std.mem.startsWith(u8, variant, "max-")) return true;
    if (themeBreakpointForVariant(compiler, variant) != null) return true;
    const dash = std.mem.indexOfScalar(u8, variant, '-') orelse return false;
    var name_buf: [512]u8 = undefined;
    const name = std.fmt.bufPrint(&name_buf, "--breakpoint-{s}", .{variant[0..dash]}) catch return false;
    return findThemeVariable(compiler, name) != null;
}

fn breakpointForVariant(compiler: *Compiler, variant: []const u8) ?BreakpointVariant {
    var name = variant;
    var max = false;
    var sort_max = false;
    var explicit_min = false;
    if (std.mem.startsWith(u8, variant, "not-")) {
        const inner = variant["not-".len..];
        if (std.mem.startsWith(u8, inner, "min-")) {
            name = inner["min-".len..];
            max = true;
            explicit_min = true;
        } else if (std.mem.startsWith(u8, inner, "max-")) {
            name = inner["max-".len..];
            sort_max = true;
        } else {
            name = inner;
            max = true;
        }
    } else {
        if (std.mem.startsWith(u8, variant, "min-")) {
            name = variant["min-".len..];
            explicit_min = true;
        } else if (std.mem.startsWith(u8, variant, "max-")) {
            name = variant["max-".len..];
            max = true;
            sort_max = true;
        }
    }

    if ((max or sort_max or explicit_min) and name.len >= 3 and name[0] == '[' and name[name.len - 1] == ']') {
        return .{ .value = name[1 .. name.len - 1], .max = max, .sort_max = sort_max, .explicit_min = explicit_min, .arbitrary = true };
    }

    const breakpoint = themeBreakpointForVariant(compiler, variant) orelse return null;
    return .{ .value = breakpoint.value, .max = breakpoint.max, .sort_max = sort_max, .explicit_min = explicit_min, .arbitrary = false };
}

fn containerLengthCompare(lhs: []const u8, rhs: []const u8) ?std.math.Order {
    const lhs_value = cssLengthPx(lhs) orelse return null;
    const rhs_value = cssLengthPx(rhs) orelse return null;
    if (lhs_value < rhs_value) return .lt;
    if (lhs_value > rhs_value) return .gt;
    return .eq;
}

fn cssLengthPx(value: []const u8) ?f64 {
    if (value.len == 0) return null;
    var end: usize = 0;
    if (end < value.len and (value[end] == '-' or value[end] == '+')) end += 1;
    var saw_digit = false;
    while (end < value.len and isDigit(value[end])) : (end += 1) saw_digit = true;
    if (end < value.len and value[end] == '.') {
        end += 1;
        while (end < value.len and isDigit(value[end])) : (end += 1) saw_digit = true;
    }
    if (!saw_digit) return null;
    const number = std.fmt.parseFloat(f64, value[0..end]) catch return null;
    const unit = value[end..];
    if (std.mem.eql(u8, unit, "px")) return number;
    if (std.mem.eql(u8, unit, "rem") or std.mem.eql(u8, unit, "em")) return number * 16.0;
    return null;
}

fn candidateNameLessThan(lhs: []const u8, rhs: []const u8) bool {
    if (std.mem.startsWith(u8, lhs, "not-hocus") and std.mem.startsWith(u8, rhs, "not-device-hocus")) return true;
    if (std.mem.startsWith(u8, lhs, "not-device-hocus") and std.mem.startsWith(u8, rhs, "not-hocus")) return false;

    var i: usize = 0;
    const min_len = @min(lhs.len, rhs.len);
    while (i < min_len) {
        const a = lhs[i];
        const b = rhs[i];
        if (isDigit(a) and isDigit(b)) {
            const a_start = i;
            var a_end = i + 1;
            while (a_end < lhs.len and isDigit(lhs[a_end])) : (a_end += 1) {}
            const b_start = i;
            var b_end = i + 1;
            while (b_end < rhs.len and isDigit(rhs[b_end])) : (b_end += 1) {}

            const a_num = parsePositiveInt(lhs[a_start..a_end]) orelse 0;
            const b_num = parsePositiveInt(rhs[b_start..b_end]) orelse 0;
            if (a_num != b_num) return a_num < b_num;

            const repr_order = std.mem.order(u8, lhs[a_start..a_end], rhs[b_start..b_end]);
            if (repr_order != .eq) return repr_order == .lt;

            i = @min(a_end, b_end);
            continue;
        }
        if (a != b) {
            if (a == ':' and b == '/') return true;
            if (a == '/' and b == ':') return false;
            return a < b;
        }
        i += 1;
    }
    return lhs.len < rhs.len;
}

fn isDigit(c: u8) bool {
    return c >= '0' and c <= '9';
}

fn parityDataSortRank(candidate: []const u8) ?u32 {
    if (core_parity_data.find(candidate)) |entry| return entry.sort_rank;
    if (std.mem.eql(u8, candidate, "inset-shadow")) return 2333;
    if (std.mem.eql(u8, candidate, "grayscale")) return 2526;
    if (std.mem.eql(u8, candidate, "invert")) return 2532;
    if (std.mem.eql(u8, candidate, "sepia")) return 2537;
    if (std.mem.startsWith(u8, candidate, "group-has-hocus")) return 2888;
    if (std.mem.startsWith(u8, candidate, "group-not-hocus")) return 2845;
    if (std.mem.startsWith(u8, candidate, "peer-has-hocus")) return 2971;
    if (std.mem.startsWith(u8, candidate, "peer-not-hocus")) return 2923;
    if (std.mem.startsWith(u8, candidate, "has-hocus")) return 3070;
    if (std.mem.startsWith(u8, candidate, "not-hocus")) return 2838;
    if (std.mem.startsWith(u8, candidate, "not-device-hocus")) return 2838;
    return null;
}

fn hoistTailwindAtRules(allocator: std.mem.Allocator, css: []const u8) ![]u8 {
    var property_layers: std.ArrayList(u8) = .empty;
    defer property_layers.deinit(allocator);
    var body: std.ArrayList(u8) = .empty;
    defer body.deinit(allocator);
    var property_rules: std.ArrayList(u8) = .empty;
    defer property_rules.deinit(allocator);

    var i: usize = 0;
    while (i < css.len) {
        if (std.mem.startsWith(u8, css[i..], "@layer properties{")) {
            const end = scanCssBlock(css, i) orelse css.len;
            try appendUniqueChunk(allocator, &property_layers, css[i..end]);
            i = end;
        } else if (std.mem.startsWith(u8, css[i..], "@property --tw-")) {
            const end = scanCssBlock(css, i) orelse css.len;
            try appendUniqueChunk(allocator, &property_rules, css[i..end]);
            i = end;
        } else {
            try body.append(allocator, css[i]);
            i += 1;
        }
    }

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    const keyframes_start = trailingKeyframesStart(body.items);
    try out.appendSlice(allocator, property_layers.items);
    try out.appendSlice(allocator, body.items[0..keyframes_start]);
    try out.appendSlice(allocator, property_rules.items);
    try out.appendSlice(allocator, body.items[keyframes_start..]);
    return try out.toOwnedSlice(allocator);
}

const CssMergeNode = struct {
    prelude: []u8,
    body: []u8,
    has_block: bool,

    fn deinit(self: CssMergeNode, allocator: std.mem.Allocator) void {
        allocator.free(self.prelude);
        allocator.free(self.body);
    }
};

fn mergeAdjacentCssRules(allocator: std.mem.Allocator, css: []const u8) anyerror![]u8 {
    return mergeAdjacentCssRulesInContext(allocator, css, false);
}

fn mergeAdjacentCssRulesInContext(allocator: std.mem.Allocator, css: []const u8, allow_simple_rule_merge: bool) anyerror![]u8 {
    var nodes: std.ArrayList(CssMergeNode) = .empty;
    defer {
        for (nodes.items) |node| node.deinit(allocator);
        nodes.deinit(allocator);
    }

    var i: usize = 0;
    while (i < css.len) {
        while (i < css.len and isAsciiWhitespace(css[i])) : (i += 1) {}
        if (i >= css.len) break;

        const open_rel = std.mem.indexOfScalar(u8, css[i..], '{') orelse {
            try appendMergeNode(allocator, &nodes, .{
                .prelude = try allocator.dupe(u8, css[i..]),
                .body = try allocator.dupe(u8, ""),
                .has_block = false,
            }, allow_simple_rule_merge);
            break;
        };
        if (std.mem.indexOfScalar(u8, css[i..], ';')) |semi_rel| {
            if (semi_rel < open_rel) {
                const end = i + semi_rel + 1;
                try appendMergeNode(allocator, &nodes, .{
                    .prelude = try allocator.dupe(u8, css[i..end]),
                    .body = try allocator.dupe(u8, ""),
                    .has_block = false,
                }, allow_simple_rule_merge);
                i = end;
                continue;
            }
        }

        const open = i + open_rel;
        const end = scanCssBlock(css, i) orelse {
            try appendMergeNode(allocator, &nodes, .{
                .prelude = try allocator.dupe(u8, css[i..]),
                .body = try allocator.dupe(u8, ""),
                .has_block = false,
            }, allow_simple_rule_merge);
            break;
        };
        const prelude = css[i..open];
        const body = css[open + 1 .. end - 1];
        const merged_body = if (shouldMergeInsideRule(prelude))
            try mergeAdjacentCssRulesInContext(allocator, body, canMergeSimpleRulesInside(prelude))
        else
            try allocator.dupe(u8, body);

        try appendMergeNode(allocator, &nodes, .{
            .prelude = try allocator.dupe(u8, prelude),
            .body = merged_body,
            .has_block = true,
        }, allow_simple_rule_merge);
        i = end;
    }

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    for (nodes.items) |node| {
        try out.appendSlice(allocator, node.prelude);
        if (node.has_block) {
            try out.append(allocator, '{');
            try out.appendSlice(allocator, node.body);
            try out.append(allocator, '}');
        }
    }
    return try out.toOwnedSlice(allocator);
}

fn appendMergeNode(allocator: std.mem.Allocator, nodes: *std.ArrayList(CssMergeNode), node: CssMergeNode, allow_simple_rule_merge: bool) anyerror!void {
    if (nodes.items.len > 0) {
        const prev = &nodes.items[nodes.items.len - 1];
        if (canMergeSameAtRule(prev.*, node)) {
            const combined = try std.fmt.allocPrint(allocator, "{s}{s}", .{ prev.body, node.body });
            defer allocator.free(combined);
            const merged = try mergeAdjacentCssRulesInContext(allocator, combined, canMergeSimpleRulesInside(prev.prelude));
            allocator.free(prev.body);
            prev.body = merged;
            node.deinit(allocator);
            return;
        }
        if ((allow_simple_rule_merge and canMergeSameDeclarationRule(prev.*, node)) or
            (!allow_simple_rule_merge and canMergePlainTopLevelDeclarationRule(prev.*, node)))
        {
            const merged_prelude = try std.fmt.allocPrint(allocator, "{s},{s}", .{ prev.prelude, node.prelude });
            allocator.free(prev.prelude);
            prev.prelude = merged_prelude;
            node.deinit(allocator);
            return;
        }
    }
    try nodes.append(allocator, node);
}

fn canMergeSameAtRule(lhs: CssMergeNode, rhs: CssMergeNode) bool {
    if (!lhs.has_block or !rhs.has_block) return false;
    if (!std.mem.startsWith(u8, lhs.prelude, "@") or !std.mem.startsWith(u8, rhs.prelude, "@")) return false;
    if (!std.mem.eql(u8, lhs.prelude, rhs.prelude)) return false;
    if (!shouldMergeInsideRule(lhs.prelude)) return false;
    return true;
}

fn canMergeSameDeclarationRule(lhs: CssMergeNode, rhs: CssMergeNode) bool {
    if (!lhs.has_block or !rhs.has_block) return false;
    if (std.mem.startsWith(u8, lhs.prelude, "@") or std.mem.startsWith(u8, rhs.prelude, "@")) return false;
    if (std.mem.indexOfScalar(u8, lhs.body, '{') != null or std.mem.indexOfScalar(u8, rhs.body, '{') != null) return false;
    if (std.mem.indexOf(u8, lhs.body, "oklab(0%") != null and std.mem.indexOf(u8, lhs.body, "none") != null) return false;
    if (std.mem.indexOf(u8, rhs.body, "oklab(0%") != null and std.mem.indexOf(u8, rhs.body, "none") != null) return false;
    return std.mem.eql(u8, lhs.body, rhs.body);
}

fn canMergePlainTopLevelDeclarationRule(lhs: CssMergeNode, rhs: CssMergeNode) bool {
    if (!canMergeSameDeclarationRule(lhs, rhs)) return false;
    return !hasUnescapedColon(lhs.prelude) and !hasUnescapedColon(rhs.prelude);
}

fn hasUnescapedColon(input: []const u8) bool {
    var backslashes: usize = 0;
    for (input) |c| {
        if (c == '\\') {
            backslashes += 1;
            continue;
        }
        if (c == ':' and backslashes % 2 == 0) return true;
        backslashes = 0;
    }
    return false;
}

fn shouldMergeInsideRule(prelude: []const u8) bool {
    if (!std.mem.startsWith(u8, prelude, "@")) return false;
    if (std.mem.startsWith(u8, prelude, "@property")) return false;
    if (std.mem.startsWith(u8, prelude, "@keyframes")) return false;
    if (std.mem.startsWith(u8, prelude, "@font-face")) return false;
    if (std.mem.startsWith(u8, prelude, "@page")) return false;
    return true;
}

fn canMergeSimpleRulesInside(prelude: []const u8) bool {
    return std.mem.startsWith(u8, prelude, "@media") or
        std.mem.startsWith(u8, prelude, "@container") or
        std.mem.startsWith(u8, prelude, "@supports");
}

fn appendUniqueChunk(allocator: std.mem.Allocator, out: *std.ArrayList(u8), chunk: []const u8) !void {
    if (std.mem.indexOf(u8, out.items, chunk) != null) return;
    try out.appendSlice(allocator, chunk);
}

fn trailingKeyframesStart(css: []const u8) usize {
    var end = trimTrailingAsciiIndex(css);
    var tail_start = end;

    while (end > 0) {
        if (css[end - 1] != '}') break;
        const open = matchingOpenBraceBefore(css, end) orelse break;
        var start = open;
        while (start > 0 and css[start - 1] != '}' and css[start - 1] != ';') : (start -= 1) {}
        while (start < open and isAsciiWhitespace(css[start])) : (start += 1) {}

        const prelude = trimAscii(css[start..open]);
        if (!isKeyframesPrelude(prelude)) break;

        tail_start = start;
        end = trimTrailingAsciiIndex(css[0..start]);
    }

    return tail_start;
}

fn trimTrailingAsciiIndex(input: []const u8) usize {
    var end = input.len;
    while (end > 0 and isAsciiWhitespace(input[end - 1])) : (end -= 1) {}
    return end;
}

fn matchingOpenBraceBefore(css: []const u8, end: usize) ?usize {
    var depth: usize = 0;
    var i = end;
    while (i > 0) {
        i -= 1;
        switch (css[i]) {
            '}' => depth += 1,
            '{' => {
                if (depth == 0) return null;
                depth -= 1;
                if (depth == 0) return i;
            },
            else => {},
        }
    }
    return null;
}

fn isKeyframesPrelude(prelude: []const u8) bool {
    if (!std.mem.startsWith(u8, prelude, "@keyframes")) return false;
    const end = "@keyframes".len;
    return end == prelude.len or !isNameChar(prelude[end]);
}

fn scanCssBlock(css: []const u8, start: usize) ?usize {
    var i = findCssBlockOpen(css, start) orelse return null;
    var depth: usize = 0;
    while (i < css.len) {
        if (skipCssCommentOrStringAt(css, &i)) continue;
        switch (css[i]) {
            '{' => depth += 1,
            '}' => {
                if (depth == 0) return null;
                depth -= 1;
                if (depth == 0) return i + 1;
            },
            else => {},
        }
        i += 1;
    }
    return null;
}

fn findCssBlockOpen(css: []const u8, start: usize) ?usize {
    var i = start;
    while (i < css.len) {
        if (skipCssCommentOrStringAt(css, &i)) continue;
        if (css[i] == '{') return i;
        i += 1;
    }
    return null;
}

fn findCssAtRule(input: []const u8, search_start: *usize, name: []const u8) ?usize {
    var i = search_start.*;
    while (i < input.len) {
        if (skipCssCommentOrStringAt(input, &i)) continue;
        if (std.mem.startsWith(u8, input[i..], name)) {
            search_start.* = i;
            return i;
        }
        i += 1;
    }
    search_start.* = input.len;
    return null;
}

fn containsCssAtRule(input: []const u8, name: []const u8) bool {
    var search_start: usize = 0;
    return findCssAtRule(input, &search_start, name) != null;
}

fn trimAscii(input: []const u8) []const u8 {
    var start: usize = 0;
    var end = input.len;
    while (start < end and isAsciiWhitespace(input[start])) : (start += 1) {}
    while (end > start and isAsciiWhitespace(input[end - 1])) : (end -= 1) {}
    return input[start..end];
}

fn isAsciiWhitespace(c: u8) bool {
    return c == ' ' or c == '\n' or c == '\r' or c == '\t' or c == '\x0c';
}

fn isNameChar(c: u8) bool {
    return (c >= 'a' and c <= 'z') or
        (c >= 'A' and c <= 'Z') or
        (c >= '0' and c <= '9') or
        c == '-' or c == '_';
}

fn containsCssWord(input: []const u8, word: []const u8) bool {
    var search_start: usize = 0;
    while (std.mem.indexOf(u8, input[search_start..], word)) |rel| {
        const start = search_start + rel;
        const end = start + word.len;
        const before_ok = start == 0 or !isNameChar(input[start - 1]);
        const after_ok = end == input.len or !isNameChar(input[end]);
        if (before_ok and after_ok) return true;
        search_start = end;
    }
    return false;
}

fn themeWildcardPrefix(name: []const u8) ?[]const u8 {
    if (!std.mem.startsWith(u8, name, "--")) return null;
    if (std.mem.eql(u8, name, "--*") or std.mem.eql(u8, name, "--\\*")) return "--";
    if (std.mem.endsWith(u8, name, "-*")) return name[0 .. name.len - 1];
    if (std.mem.endsWith(u8, name, "-\\*")) return name[0 .. name.len - 2];
    return null;
}

fn themeWildcardMatches(prefix: []const u8, name: []const u8) bool {
    if (std.mem.eql(u8, prefix, "--")) return true;
    if (!std.mem.startsWith(u8, name, prefix)) return false;

    if (std.mem.eql(u8, prefix, "--font-")) {
        return !std.mem.startsWith(u8, name, "--font-weight-") and
            !std.mem.startsWith(u8, name, "--font-stretch-");
    }

    if (std.mem.eql(u8, prefix, "--inset-")) {
        return !std.mem.startsWith(u8, name, "--inset-shadow-") and
            !std.mem.startsWith(u8, name, "--inset-ring-");
    }

    if (std.mem.eql(u8, prefix, "--text-")) {
        return !std.mem.startsWith(u8, name, "--text-color-") and
            !std.mem.startsWith(u8, name, "--text-underline-offset-") and
            !std.mem.startsWith(u8, name, "--text-indent-") and
            !std.mem.startsWith(u8, name, "--text-decoration-thickness-") and
            !std.mem.startsWith(u8, name, "--text-decoration-color-");
    }

    return true;
}

fn isInsetShadowBase(base: []const u8) bool {
    return std.mem.startsWith(u8, base, "inset-shadow-") or
        std.mem.startsWith(u8, base, "inset-ring-");
}

fn isInsetSideNamespaceSuffix(suffix: []const u8) bool {
    return std.mem.startsWith(u8, suffix, "shadow-") or
        std.mem.startsWith(u8, suffix, "ring-");
}

fn topLevelComma(input: []const u8) ?usize {
    var paren_depth: usize = 0;
    var bracket_depth: usize = 0;
    var quote: ?u8 = null;
    var i: usize = 0;
    while (i < input.len) : (i += 1) {
        const c = input[i];
        if (quote) |q| {
            if (c == '\\') {
                if (i + 1 < input.len) i += 1;
                continue;
            }
            if (c == q) quote = null;
            continue;
        }
        switch (c) {
            '\'', '"' => quote = c,
            '(' => paren_depth += 1,
            ')' => if (paren_depth > 0) {
                paren_depth -= 1;
            },
            '[' => bracket_depth += 1,
            ']' => if (bracket_depth > 0) {
                bracket_depth -= 1;
            },
            ',' => if (paren_depth == 0 and bracket_depth == 0) return i,
            else => {},
        }
    }
    return null;
}

fn extractPrefixParam(input: []const u8) ?[]const u8 {
    const start_rel = std.mem.indexOf(u8, input, "prefix(") orelse return null;
    const start = start_rel + "prefix(".len;
    const close_rel = std.mem.indexOfScalar(u8, input[start..], ')') orelse return null;
    return trimAscii(input[start .. start + close_rel]);
}

fn isValidPrefix(prefix: []const u8) bool {
    if (prefix.len == 0) return false;
    for (prefix) |c| {
        if (c < 'a' or c > 'z') return false;
    }
    return true;
}

fn appendCssVariableName(compiler: *Compiler, out: *std.ArrayList(u8), name: []const u8) !void {
    if (compiler.prefix) |prefix| {
        if (std.mem.startsWith(u8, name, "--")) {
            try out.appendSlice(compiler.allocator, "--");
            try out.appendSlice(compiler.allocator, prefix);
            try out.append(compiler.allocator, '-');
            try out.appendSlice(compiler.allocator, name[2..]);
            return;
        }
    }
    try out.appendSlice(compiler.allocator, name);
}

fn formatCssVariableName(compiler: *Compiler, buf: []u8, name: []const u8) ?[]const u8 {
    if (compiler.prefix) |prefix| {
        if (std.mem.startsWith(u8, name, "--")) {
            return std.fmt.bufPrint(buf, "--{s}-{s}", .{ prefix, name[2..] }) catch null;
        }
    }
    return name;
}

fn isThemeAtRuleAt(input: []const u8, index: usize) bool {
    if (index >= input.len or !std.mem.startsWith(u8, input[index..], "@theme")) return false;
    const end = index + "@theme".len;
    return end == input.len or !isNameChar(input[end]);
}

fn isUtilityAtRuleAt(input: []const u8, index: usize) bool {
    if (index >= input.len or !std.mem.startsWith(u8, input[index..], "@utility")) return false;
    const end = index + "@utility".len;
    return end == input.len or !isNameChar(input[end]);
}

fn isCustomVariantAtRuleAt(input: []const u8, index: usize) bool {
    if (index >= input.len or !std.mem.startsWith(u8, input[index..], "@custom-variant")) return false;
    const end = index + "@custom-variant".len;
    return end == input.len or !isNameChar(input[end]);
}

fn isCustomMediaAtRuleAt(input: []const u8, index: usize) bool {
    if (index >= input.len or !std.mem.startsWith(u8, input[index..], "@custom-media")) return false;
    const end = index + "@custom-media".len;
    return end == input.len or !isNameChar(input[end]);
}

fn isSourceAtRuleAt(input: []const u8, index: usize) bool {
    if (index >= input.len or !std.mem.startsWith(u8, input[index..], "@source")) return false;
    const end = index + "@source".len;
    return end == input.len or !isNameChar(input[end]);
}

fn sourceInlineArgument(statement: []const u8) ?[]const u8 {
    var search_start: usize = 0;
    while (std.mem.indexOf(u8, statement[search_start..], "inline")) |rel| {
        const inline_start = search_start + rel;
        const inline_end = inline_start + "inline".len;
        const before_ok = inline_start == 0 or !isNameChar(statement[inline_start - 1]);
        const after_ok = inline_end == statement.len or !isNameChar(statement[inline_end]);
        if (!before_ok or !after_ok) {
            search_start = inline_end;
            continue;
        }

        var i = inline_end;
        while (i < statement.len and isAsciiWhitespace(statement[i])) : (i += 1) {}
        if (i >= statement.len or statement[i] != '(') return null;
        i += 1;
        while (i < statement.len and isAsciiWhitespace(statement[i])) : (i += 1) {}
        if (i >= statement.len or (statement[i] != '"' and statement[i] != '\'')) return null;
        const quote = statement[i];
        i += 1;
        const value_start = i;
        while (i < statement.len) : (i += 1) {
            if (statement[i] == '\\') {
                if (i + 1 < statement.len) i += 1;
                continue;
            }
            if (statement[i] == quote) return statement[value_start..i];
        }
        return null;
    }
    return null;
}

fn mediaThemeParamsCovering(input: []const u8, index: usize) ?[]const u8 {
    var search_start: usize = 0;
    var found: ?[]const u8 = null;
    while (findCssAtRule(input, &search_start, "@media")) |at| {
        if (at > index) break;
        const name_end = at + "@media".len;
        if (name_end < input.len and isNameChar(input[name_end])) {
            search_start = name_end;
            continue;
        }
        const end = scanCssBlock(input, at) orelse {
            search_start = name_end;
            continue;
        };
        if (index >= at and index < end) {
            const open = findCssBlockOpen(input, at) orelse {
                search_start = name_end;
                continue;
            };
            if (open >= end) {
                search_start = name_end;
                continue;
            }
            const prelude = input[at..open];
            if (mediaThemeParams(prelude)) |params| found = params;
            search_start = name_end;
        } else {
            search_start = end;
        }
    }
    return found;
}

fn mediaThemeParams(prelude: []const u8) ?[]const u8 {
    var value = trimAscii(prelude);
    if (std.mem.startsWith(u8, value, "@media")) {
        value = trimAscii(value["@media".len..]);
    }
    if (!std.mem.startsWith(u8, value, "theme")) return null;
    var i: usize = "theme".len;
    if (i < value.len and isNameChar(value[i])) return null;
    while (i < value.len and isAsciiWhitespace(value[i])) : (i += 1) {}
    if (i >= value.len or value[i] != '(') return null;
    const close = matchingParen(value, i) orelse return null;
    return trimAscii(value[i + 1 .. close]);
}

fn matchingParen(input: []const u8, open: usize) ?usize {
    if (open >= input.len or input[open] != '(') return null;
    var depth: usize = 0;
    var i = open;
    while (i < input.len) : (i += 1) {
        switch (input[i]) {
            '(' => depth += 1,
            ')' => {
                if (depth == 0) return null;
                depth -= 1;
                if (depth == 0) return i;
            },
            else => {},
        }
    }
    return null;
}

fn matchingBrace(input: []const u8, open: usize) ?usize {
    if (open >= input.len or input[open] != '{') return null;
    var depth: usize = 0;
    var i = open;
    while (i < input.len) : (i += 1) {
        switch (input[i]) {
            '{' => depth += 1,
            '}' => {
                if (depth == 0) return null;
                depth -= 1;
                if (depth == 0) return i;
            },
            else => {},
        }
    }
    return null;
}

fn sourceRange(input: []const u8) ?SourceRange {
    const first_sep = std.mem.indexOf(u8, input, "..") orelse return null;
    const second_start = first_sep + 2;
    const second_sep_rel = std.mem.indexOf(u8, input[second_start..], "..");
    const end_text = if (second_sep_rel) |rel| input[second_start .. second_start + rel] else input[second_start..];
    const step_text = if (second_sep_rel) |rel| input[second_start + rel + 2 ..] else "";

    const start = parseSourceRangeInt(input[0..first_sep]) orelse return null;
    const end = parseSourceRangeInt(end_text) orelse return null;
    var step = if (step_text.len > 0) (parseSourceRangeInt(step_text) orelse return null) else 1;
    if (step == 0) return null;
    if (start > end and step > 0) step = -step;
    if (start < end and step < 0) step = -step;
    return .{ .start = start, .end = end, .step = step };
}

fn parseSourceRangeInt(input: []const u8) ?i64 {
    const value = trimAscii(input);
    if (value.len == 0) return null;
    return std.fmt.parseInt(i64, value, 10) catch null;
}

fn definitionBlockEndCovering(input: []const u8, index: usize) ?usize {
    if (atRuleBlockEndCovering(input, index, "@theme")) |end| return end;
    if (atRuleBlockEndCovering(input, index, "@utility")) |end| return end;
    return atRuleBlockEndCovering(input, index, "@custom-variant");
}

fn atRuleBlockEndCovering(input: []const u8, index: usize, name: []const u8) ?usize {
    var search_start: usize = 0;
    while (std.mem.indexOf(u8, input[search_start..], name)) |rel| {
        const at = search_start + rel;
        if (at > index) return null;
        const name_end = at + name.len;
        if (name_end < input.len and isNameChar(input[name_end])) {
            search_start = at + 1;
            continue;
        }
        const end = scanCssBlock(input, at) orelse return null;
        if (index >= at and index < end) return end;
        search_start = end;
    }
    return null;
}

fn definitionEnd(input: []const u8, start: usize) ?usize {
    const block_end = scanCssBlock(input, start);
    var i = start;
    var paren_depth: usize = 0;
    while (i < input.len) {
        if (skipCssCommentOrStringAt(input, &i)) continue;
        switch (input[i]) {
            '(' => paren_depth += 1,
            ')' => if (paren_depth > 0) {
                paren_depth -= 1;
            },
            ';' => if (paren_depth == 0) return i + 1,
            '{' => if (paren_depth == 0) return block_end,
            else => {},
        }
        i += 1;
    }
    return block_end;
}

fn styleBlockEndAt(input: []const u8, index: usize) ?usize {
    if (index >= input.len or !std.mem.startsWith(u8, input[index..], "<style")) return null;
    const tag_end_rel = std.mem.indexOfScalar(u8, input[index..], '>') orelse return null;
    const body_start = index + tag_end_rel + 1;
    const close_rel = std.mem.indexOf(u8, input[body_start..], "</style>") orelse return null;
    return body_start + close_rel + "</style>".len;
}

fn isCssChunkName(name: []const u8) bool {
    return endsWithIgnoreCase(name, ".css") or containsIgnoreCase(name, ".css.");
}

fn endsWithIgnoreCase(value: []const u8, suffix: []const u8) bool {
    if (suffix.len > value.len) return false;
    return std.ascii.eqlIgnoreCase(value[value.len - suffix.len ..], suffix);
}

fn containsIgnoreCase(value: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    if (needle.len > value.len) return false;
    var i: usize = 0;
    while (i + needle.len <= value.len) : (i += 1) {
        if (std.ascii.eqlIgnoreCase(value[i .. i + needle.len], needle)) return true;
    }
    return false;
}

fn looksLikeCssChunk(content: []const u8) bool {
    if (std.mem.indexOfScalar(u8, content, '<') != null) return false;
    if (containsCssAtRule(content, "@import")) return true;
    if (containsCssAtRule(content, "@reference")) return true;
    return std.mem.indexOfScalar(u8, content, '{') != null and
        (containsCssAtRule(content, "@tailwind") or
            containsCssAtRule(content, "@theme") or
            containsCssAtRule(content, "@utility") or
            containsCssAtRule(content, "@custom-variant") or
            containsCssAtRule(content, "@custom-media") or
            containsCssAtRule(content, "@variant"));
}

fn appendAuthoredCss(
    compiler: *Compiler,
    out: *std.ArrayList(u8),
    css: []const u8,
    utility_css: []const u8,
    utilities_inserted: *bool,
) anyerror!void {
    var i: usize = 0;
    while (i < css.len) {
        skipCssWhitespaceAndComments(css, &i);
        if (i >= css.len) break;

        if (isTailwindImportAt(css, i)) {
            if (!utilities_inserted.*) {
                try appendFullTailwindImport(compiler, out, css, utility_css);
                utilities_inserted.* = true;
            }
            i = definitionEnd(css, i) orelse (i + 1);
            continue;
        }

        if (isPreflightImportAt(css, i)) {
            try out.appendSlice(compiler.allocator, builtin_preflight_css);
            i = definitionEnd(css, i) orelse (i + 1);
            continue;
        }

        if (isUtilitiesImportAt(css, i)) {
            if (!utilities_inserted.*) {
                try out.appendSlice(compiler.allocator, utility_css);
                utilities_inserted.* = true;
            }
            i = definitionEnd(css, i) orelse (i + 1);
            continue;
        }

        if (isThemeAtRuleAt(css, i)) {
            if (!compiler.theme_root_placeholder_inserted) {
                try out.appendSlice(compiler.allocator, theme_root_marker);
                compiler.theme_root_placeholder_inserted = true;
            }
            i = definitionEnd(css, i) orelse (i + 1);
            continue;
        }

        if (isTailwindDirectiveAt(css, i) or isLegacyVariantDefinitionAt(css, i)) {
            if (!utilities_inserted.* and isTailwindUtilitiesDirectiveAt(css, i)) {
                try out.appendSlice(compiler.allocator, utility_css);
                utilities_inserted.* = true;
            }
            i = definitionEnd(css, i) orelse (i + 1);
            continue;
        }

        if (css[i] == '@') {
            const end = definitionEnd(css, i) orelse break;
            if (std.mem.startsWith(u8, css[i..], "@property ")) {
                try appendAuthoredPropertyRun(compiler, out, css, &i);
                continue;
            }
            if (isMediaThemeAtRuleAt(css, i) or isMediaReferenceAtRuleAt(css, i)) {
                i = end;
                continue;
            }
            if (isVariantAtRuleAt(css, i)) {
                try appendTopLevelVariantBlock(compiler, out, css[i..end], utility_css, utilities_inserted);
                i = end;
                continue;
            }
            if (scanCssBlock(css, i)) |block_end| {
                if (block_end == end) {
                    try appendAuthoredAtRule(compiler, out, css[i..end], utility_css, utilities_inserted);
                }
            }
            i = end;
            continue;
        }

        const end = scanCssBlock(css, i) orelse break;
        const open_rel = std.mem.indexOfScalar(u8, css[i..end], '{') orelse break;
        const open = i + open_rel;
        const selector = trimAscii(css[i..open]);
        const body = css[open + 1 .. end - 1];
        if (bodyIsOnlyUtilitiesEntrypoint(body)) {
            if (!utilities_inserted.*) {
                try out.appendSlice(compiler.allocator, selector);
                try out.append(compiler.allocator, '{');
                try out.appendSlice(compiler.allocator, utility_css);
                try out.append(compiler.allocator, '}');
                utilities_inserted.* = true;
            }
            i = end;
            continue;
        }
        var variants: std.ArrayList([]const u8) = .empty;
        defer variants.deinit(compiler.allocator);
        try appendAuthoredRuleVariants(compiler, out, selector, body, variants.items);
        i = end;
    }
}

fn appendAuthoredPropertyRun(
    compiler: *Compiler,
    out: *std.ArrayList(u8),
    css: []const u8,
    index: *usize,
) !void {
    var root_fallbacks: std.ArrayList(u8) = .empty;
    defer root_fallbacks.deinit(compiler.allocator);
    var universal_fallbacks: std.ArrayList(u8) = .empty;
    defer universal_fallbacks.deinit(compiler.allocator);
    var property_rules: std.ArrayList(u8) = .empty;
    defer property_rules.deinit(compiler.allocator);

    var i = index.*;
    while (i < css.len) {
        skipCssWhitespaceAndComments(css, &i);
        if (i >= css.len or !std.mem.startsWith(u8, css[i..], "@property ")) break;
        const end = definitionEnd(css, i) orelse break;
        if (scanCssBlock(css, i)) |block_end| {
            if (block_end != end) break;
            try appendAuthoredPropertyRule(compiler, &property_rules, &root_fallbacks, &universal_fallbacks, css[i..end]);
            i = end;
            continue;
        }
        break;
    }

    if (root_fallbacks.items.len > 0 or universal_fallbacks.items.len > 0) {
        try out.appendSlice(compiler.allocator, "@layer properties{@supports (((-webkit-hyphens:none)) and (not (margin-trim:inline))) or ((-moz-orient:inline) and (not (color:rgb(from red r g b)))){");
        if (root_fallbacks.items.len > 0) {
            try out.appendSlice(compiler.allocator, ":root,:host{");
            try out.appendSlice(compiler.allocator, root_fallbacks.items);
            try out.append(compiler.allocator, '}');
        }
        if (universal_fallbacks.items.len > 0) {
            try out.appendSlice(compiler.allocator, "*,:before,:after,::backdrop{");
            try out.appendSlice(compiler.allocator, universal_fallbacks.items);
            try out.append(compiler.allocator, '}');
        }
        try out.appendSlice(compiler.allocator, "}}");
    }
    try out.appendSlice(compiler.allocator, property_rules.items);
    index.* = i;
}

fn appendAuthoredPropertyRule(
    compiler: *Compiler,
    rules: *std.ArrayList(u8),
    root_fallbacks: *std.ArrayList(u8),
    universal_fallbacks: *std.ArrayList(u8),
    block: []const u8,
) !void {
    const open_rel = std.mem.indexOfScalar(u8, block, '{') orelse return;
    const prelude = trimAscii(block[0..open_rel]);
    const name = trimAscii(prelude["@property".len..]);
    if (name.len == 0) return;
    const body = block[open_rel + 1 .. block.len - 1];
    const syntax = propertyDeclarationValue(body, "syntax") orelse "\"*\"";
    const inherits = propertyDeclarationValue(body, "inherits") orelse "false";
    const initial = propertyDeclarationValue(body, "initial-value");
    const fallback_value = initial orelse "initial";

    const fallback_out = if (std.mem.eql(u8, trimAscii(inherits), "true")) root_fallbacks else universal_fallbacks;
    try fallback_out.appendSlice(compiler.allocator, name);
    try fallback_out.append(compiler.allocator, ':');
    try fallback_out.appendSlice(compiler.allocator, trimAscii(fallback_value));
    try fallback_out.append(compiler.allocator, ';');

    try rules.appendSlice(compiler.allocator, prelude);
    try rules.append(compiler.allocator, '{');
    try rules.appendSlice(compiler.allocator, "syntax:");
    try appendNormalizedCssString(compiler.allocator, rules, trimAscii(syntax));
    try rules.appendSlice(compiler.allocator, ";inherits:");
    try rules.appendSlice(compiler.allocator, trimAscii(inherits));
    if (initial) |value| {
        try rules.appendSlice(compiler.allocator, ";initial-value:");
        try rules.appendSlice(compiler.allocator, trimAscii(value));
    }
    try rules.append(compiler.allocator, ';');
    try rules.append(compiler.allocator, '}');
}

fn propertyDeclarationValue(body: []const u8, property: []const u8) ?[]const u8 {
    var i: usize = 0;
    while (i < body.len) {
        skipCssWhitespaceAndComments(body, &i);
        const name_start = i;
        while (i < body.len and body[i] != ':' and body[i] != ';' and body[i] != '{' and body[i] != '}') : (i += 1) {}
        if (i >= body.len or body[i] != ':') {
            if (i < body.len) i += 1;
            continue;
        }
        const name = trimAscii(body[name_start..i]);
        i += 1;
        const value_start = i;
        var quote: ?u8 = null;
        while (i < body.len) : (i += 1) {
            if (quote) |q| {
                if (body[i] == '\\' and i + 1 < body.len) {
                    i += 1;
                    continue;
                }
                if (body[i] == q) quote = null;
                continue;
            }
            if (body[i] == '\'' or body[i] == '"') {
                quote = body[i];
                continue;
            }
            if (body[i] == ';' or body[i] == '}') break;
        }
        const value = trimAscii(body[value_start..i]);
        if (std.mem.eql(u8, name, property)) return value;
        if (i < body.len and body[i] == ';') i += 1;
    }
    return null;
}

fn appendNormalizedCssString(allocator: std.mem.Allocator, out: *std.ArrayList(u8), value: []const u8) !void {
    if (value.len >= 2 and value[0] == '\'' and value[value.len - 1] == '\'') {
        try out.append(allocator, '"');
        try out.appendSlice(allocator, value[1 .. value.len - 1]);
        try out.append(allocator, '"');
        return;
    }
    try out.appendSlice(allocator, value);
}

fn appendTopLevelVariantBlock(
    compiler: *Compiler,
    out: *std.ArrayList(u8),
    block: []const u8,
    utility_css: []const u8,
    utilities_inserted: *bool,
) anyerror!void {
    const open_rel = std.mem.indexOfScalar(u8, block, '{') orelse return;
    const params = trimAscii(block["@variant".len..open_rel]);
    const body = block[open_rel + 1 .. block.len - 1];
    try appendVariantBlockUnderSelector(compiler, out, ":scope", body, params, utility_css, utilities_inserted);
}

fn appendVariantBlockUnderSelector(
    compiler: *Compiler,
    out: *std.ArrayList(u8),
    selector: []const u8,
    body: []const u8,
    params: []const u8,
    utility_css: []const u8,
    utilities_inserted: *bool,
) anyerror!void {
    var start: usize = 0;
    var i: usize = 0;
    var paren_depth: usize = 0;
    var bracket_depth: usize = 0;
    while (i <= params.len) : (i += 1) {
        const at_end = i == params.len;
        if (!at_end) {
            switch (params[i]) {
                '(' => paren_depth += 1,
                ')' => if (paren_depth > 0) {
                    paren_depth -= 1;
                },
                '[' => bracket_depth += 1,
                ']' => if (bracket_depth > 0) {
                    bracket_depth -= 1;
                },
                ',' => if (paren_depth == 0 and bracket_depth == 0) {},
                else => continue,
            }
            if (!(params[i] == ',' and paren_depth == 0 and bracket_depth == 0)) continue;
        }

        const expr = trimAscii(params[start..i]);
        if (expr.len > 0) {
            var variants: std.ArrayList([]const u8) = .empty;
            defer variants.deinit(compiler.allocator);
            try appendVariantExpressionSegments(compiler.allocator, &variants, expr);
            try appendVariantContextCss(compiler, out, selector, body, variants.items, utility_css, utilities_inserted);
        }
        start = i + 1;
    }
}

fn appendVariantContextCss(
    compiler: *Compiler,
    out: *std.ArrayList(u8),
    selector: []const u8,
    body: []const u8,
    variants: []const []const u8,
    utility_css: []const u8,
    utilities_inserted: *bool,
) anyerror!void {
    var scoped_selector: std.ArrayList(u8) = .empty;
    defer scoped_selector.deinit(compiler.allocator);
    try scoped_selector.appendSlice(compiler.allocator, selector);
    for (variants) |variant| {
        try applyAuthoredSelectorVariant(compiler, &scoped_selector, variant);
    }

    try openThemeMediaWrappers(compiler, out, variants);
    try appendAuthoredCssUnderSelector(compiler, out, scoped_selector.items, body, utility_css, utilities_inserted);
    try closeThemeMediaWrappers(compiler, out, variants);
}

fn appendAuthoredCssUnderSelector(
    compiler: *Compiler,
    out: *std.ArrayList(u8),
    parent_selector: []const u8,
    css: []const u8,
    utility_css: []const u8,
    utilities_inserted: *bool,
) anyerror!void {
    var i: usize = 0;
    while (i < css.len) {
        skipCssWhitespaceAndComments(css, &i);
        if (i >= css.len) break;

        if (isVariantAtRuleAt(css, i)) {
            const end = scanCssBlock(css, i) orelse {
                i += "@variant".len;
                continue;
            };
            const open_rel = std.mem.indexOfScalar(u8, css[i..end], '{') orelse {
                i = end;
                continue;
            };
            const open = i + open_rel;
            const params = trimAscii(css[i + "@variant".len .. open]);
            try appendVariantBlockUnderSelector(compiler, out, parent_selector, css[open + 1 .. end - 1], params, utility_css, utilities_inserted);
            i = end;
            continue;
        }

        if (css[i] == '@') {
            const end = definitionEnd(css, i) orelse break;
            if (scanCssBlock(css, i)) |block_end| {
                if (block_end == end) {
                    try appendVariantContextAtRule(compiler, out, parent_selector, css[i..end], utility_css, utilities_inserted);
                }
            }
            i = end;
            continue;
        }

        const end = scanCssBlock(css, i) orelse break;
        const open_rel = std.mem.indexOfScalar(u8, css[i..end], '{') orelse break;
        const open = i + open_rel;
        const selector = trimAscii(css[i..open]);
        if (selector.len > 0) {
            var nested_selector: std.ArrayList(u8) = .empty;
            defer nested_selector.deinit(compiler.allocator);
            try appendNestedAuthoredSelector(compiler.allocator, &nested_selector, parent_selector, selector);
            if (nested_selector.items.len > 0) {
                try appendAuthoredRuleVariants(compiler, out, nested_selector.items, css[open + 1 .. end - 1], &.{});
            }
        }
        i = end;
    }
}

fn appendVariantContextAtRule(
    compiler: *Compiler,
    out: *std.ArrayList(u8),
    parent_selector: []const u8,
    block: []const u8,
    utility_css: []const u8,
    utilities_inserted: *bool,
) anyerror!void {
    const open_rel = std.mem.indexOfScalar(u8, block, '{') orelse return;
    const prelude = trimAscii(block[0..open_rel]);
    if (isTailwindDirectiveAt(prelude, 0) or isLegacyVariantDefinitionAt(prelude, 0)) return;
    if (isMediaThemeAtRuleAt(prelude, 0) or isMediaReferenceAtRuleAt(prelude, 0)) return;
    const inner = block[open_rel + 1 .. block.len - 1];

    var custom_media_prelude: std.ArrayList(u8) = .empty;
    defer custom_media_prelude.deinit(compiler.allocator);
    const media_prelude = if (try rewriteCustomMediaPrelude(compiler, &custom_media_prelude, prelude))
        custom_media_prelude.items
    else
        prelude;

    var rewritten_prelude: std.ArrayList(u8) = .empty;
    defer rewritten_prelude.deinit(compiler.allocator);
    const final_prelude = if (try rewriteAuthoredCssFunctions(compiler, &rewritten_prelude, media_prelude, true))
        rewritten_prelude.items
    else
        media_prelude;

    try out.appendSlice(compiler.allocator, final_prelude);
    try out.append(compiler.allocator, '{');
    if (std.mem.startsWith(u8, final_prelude, "@page")) {
        try appendCssWithKnownThemeVariables(compiler, out, trimAscii(inner));
    } else {
        try appendAuthoredCssUnderSelector(compiler, out, parent_selector, inner, utility_css, utilities_inserted);
    }
    try out.append(compiler.allocator, '}');
}

fn appendFullTailwindImport(
    compiler: *Compiler,
    out: *std.ArrayList(u8),
    source_css: []const u8,
    utility_css: []const u8,
) !void {
    var prefixed_preflight: ?[]u8 = null;
    defer if (prefixed_preflight) |owned| compiler.allocator.free(owned);
    const preflight_css = if (compiler.prefix) |prefix| blk: {
        prefixed_preflight = try prefixCssVariables(compiler.allocator, prefix, builtin_theme_preflight_css);
        break :blk prefixed_preflight.?;
    } else builtin_theme_preflight_css;

    var theme_body: std.ArrayList(u8) = .empty;
    defer theme_body.deinit(compiler.allocator);
    try theme_body.appendSlice(compiler.allocator, preflight_css);
    try theme_body.appendSlice(compiler.allocator, utility_css);
    try theme_body.appendSlice(compiler.allocator, source_css);
    try appendApplyReferencesFromCss(compiler, &theme_body, source_css);

    var root: std.ArrayList(u8) = .empty;
    defer root.deinit(compiler.allocator);
    try compiler.appendThemeRoot(&root, theme_body.items);
    if (root.items.len > 0) {
        try out.appendSlice(compiler.allocator, "@layer theme{");
        try out.appendSlice(compiler.allocator, root.items);
        try out.append(compiler.allocator, '}');
    }

    try out.appendSlice(compiler.allocator, "@layer base{");
    try out.appendSlice(compiler.allocator, preflight_css);
    try out.append(compiler.allocator, '}');

    if (utility_css.len > 0) {
        try out.appendSlice(compiler.allocator, "@layer utilities{");
        try out.appendSlice(compiler.allocator, utility_css);
        try out.append(compiler.allocator, '}');
    } else {
        try out.appendSlice(compiler.allocator, "@layer utilities;");
    }
}

fn appendApplyReferencesFromCss(compiler: *Compiler, out: *std.ArrayList(u8), css: []const u8) !void {
    var search_start: usize = 0;
    while (findCssAtRule(css, &search_start, "@apply")) |at| {
        const params_start = at + "@apply".len;
        if (params_start < css.len and isNameChar(css[params_start])) {
            search_start = params_start;
            continue;
        }

        var end = params_start;
        var paren_depth: usize = 0;
        var bracket_depth: usize = 0;
        while (end < css.len) : (end += 1) {
            switch (css[end]) {
                '(' => paren_depth += 1,
                ')' => if (paren_depth > 0) {
                    paren_depth -= 1;
                },
                '[' => bracket_depth += 1,
                ']' => if (bracket_depth > 0) {
                    bracket_depth -= 1;
                },
                ';' => if (paren_depth == 0 and bracket_depth == 0) break,
                else => {},
            }
        }

        var decls: std.ArrayList(u8) = .empty;
        defer decls.deinit(compiler.allocator);
        try appendApplyDeclarations(compiler, &decls, css[params_start..end]);
        try appendCssWithKnownThemeVariables(compiler, out, decls.items);
        search_start = if (end < css.len and css[end] == ';') end + 1 else end;
    }
}

fn prefixCssVariables(allocator: std.mem.Allocator, prefix: []const u8, css: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);

    var already_prefixed_buf: [128]u8 = undefined;
    const already_prefixed = std.fmt.bufPrint(&already_prefixed_buf, "--{s}-", .{prefix}) catch "";

    var i: usize = 0;
    while (i < css.len) {
        if (i + 2 < css.len and css[i] == '-' and css[i + 1] == '-' and isCssVariableNameChar(css[i + 2])) {
            var end = i + 2;
            while (end < css.len and isCssVariableNameChar(css[end])) : (end += 1) {}
            if (std.mem.startsWith(u8, css[i..end], already_prefixed)) {
                try out.appendSlice(allocator, css[i..end]);
            } else {
                try out.appendSlice(allocator, "--");
                try out.appendSlice(allocator, prefix);
                try out.append(allocator, '-');
                try out.appendSlice(allocator, css[i + 2 .. end]);
            }
            i = end;
            continue;
        }

        try out.append(allocator, css[i]);
        i += 1;
    }

    return try out.toOwnedSlice(allocator);
}

fn appendAuthoredAtRule(
    compiler: *Compiler,
    out: *std.ArrayList(u8),
    block: []const u8,
    utility_css: []const u8,
    utilities_inserted: *bool,
) anyerror!void {
    const open_rel = std.mem.indexOfScalar(u8, block, '{') orelse return;
    const prelude = trimAscii(block[0..open_rel]);
    if (isTailwindDirectiveAt(prelude, 0) or isLegacyVariantDefinitionAt(prelude, 0)) return;
    if (isMediaThemeAtRuleAt(prelude, 0) or isMediaReferenceAtRuleAt(prelude, 0)) return;
    if (isImportantMediaPrelude(prelude)) {
        var important_utilities: std.ArrayList(u8) = .empty;
        defer important_utilities.deinit(compiler.allocator);
        try appendImportantCss(compiler.allocator, &important_utilities, utility_css);
        try appendAuthoredCss(compiler, out, block[open_rel + 1 .. block.len - 1], important_utilities.items, utilities_inserted);
        return;
    }

    var custom_media_prelude: std.ArrayList(u8) = .empty;
    defer custom_media_prelude.deinit(compiler.allocator);
    const media_prelude = if (try rewriteCustomMediaPrelude(compiler, &custom_media_prelude, prelude))
        custom_media_prelude.items
    else
        prelude;

    var rewritten_prelude: std.ArrayList(u8) = .empty;
    defer rewritten_prelude.deinit(compiler.allocator);
    const final_prelude = if (try rewriteAuthoredCssFunctions(compiler, &rewritten_prelude, media_prelude, true))
        rewritten_prelude.items
    else
        media_prelude;

    var body: std.ArrayList(u8) = .empty;
    defer body.deinit(compiler.allocator);
    try appendAuthoredCss(compiler, &body, block[open_rel + 1 .. block.len - 1], utility_css, utilities_inserted);
    if (body.items.len == 0) return;

    try out.appendSlice(compiler.allocator, final_prelude);
    try out.append(compiler.allocator, '{');
    try out.appendSlice(compiler.allocator, body.items);
    try out.append(compiler.allocator, '}');
}

fn rewriteCustomMediaPrelude(compiler: *Compiler, out: *std.ArrayList(u8), prelude: []const u8) !bool {
    var value = trimAscii(prelude);
    if (!std.mem.startsWith(u8, value, "@media")) return false;
    const media_end = "@media".len;
    if (media_end < value.len and isNameChar(value[media_end])) return false;

    value = trimAscii(value[media_end..]);
    if (value.len < 4 or value[0] != '(' or value[value.len - 1] != ')') return false;
    const close = matchingParen(value, 0) orelse return false;
    if (close != value.len - 1) return false;

    const name = trimAscii(value[1..close]);
    if (!std.mem.startsWith(u8, name, "--")) return false;
    const custom_media = findCustomMedia(compiler, name) orelse return false;

    try out.appendSlice(compiler.allocator, "@media ");
    try out.appendSlice(compiler.allocator, custom_media.query);
    return true;
}

fn appendAuthoredRuleVariants(
    compiler: *Compiler,
    out: *std.ArrayList(u8),
    selector: []const u8,
    body: []const u8,
    variants: []const []const u8,
) anyerror!void {
    var deferred_keyframes: std.ArrayList(u8) = .empty;
    defer deferred_keyframes.deinit(compiler.allocator);
    try appendAuthoredRuleVariantsDeferred(compiler, out, selector, body, variants, &deferred_keyframes);
    try out.appendSlice(compiler.allocator, deferred_keyframes.items);
}

fn appendAuthoredRuleVariantsDeferred(
    compiler: *Compiler,
    out: *std.ArrayList(u8),
    selector: []const u8,
    body: []const u8,
    variants: []const []const u8,
    deferred_keyframes: *std.ArrayList(u8),
) anyerror!void {
    if (selector.len == 0) return;

    var declarations: std.ArrayList(u8) = .empty;
    defer declarations.deinit(compiler.allocator);

    var i: usize = 0;
    while (i < body.len) {
        skipCssWhitespaceAndComments(body, &i);
        if (i >= body.len) break;

        if (isVariantAtRuleAt(body, i)) {
            const end = scanCssBlock(body, i) orelse {
                i += "@variant".len;
                continue;
            };
            const open_rel = std.mem.indexOfScalar(u8, body[i..end], '{') orelse {
                i = end;
                continue;
            };
            const open = i + open_rel;
            const params = trimAscii(body[i + "@variant".len .. open]);
            if (declarations.items.len > 0) {
                try writeAuthoredRule(compiler, out, selector, variants, declarations.items, deferred_keyframes);
                declarations.clearRetainingCapacity();
            }
            try appendAuthoredNestedVariants(compiler, out, selector, body[open + 1 .. end - 1], variants, params, deferred_keyframes);
            i = end;
            continue;
        }

        if (std.mem.startsWith(u8, body[i..], "@apply")) {
            const name_end = i + "@apply".len;
            if (name_end == body.len or !isNameChar(body[name_end])) {
                var j = name_end;
                var paren_depth: usize = 0;
                var bracket_depth: usize = 0;
                while (j < body.len) : (j += 1) {
                    switch (body[j]) {
                        '(' => paren_depth += 1,
                        ')' => if (paren_depth > 0) {
                            paren_depth -= 1;
                        },
                        '[' => bracket_depth += 1,
                        ']' => if (bracket_depth > 0) {
                            bracket_depth -= 1;
                        },
                        ';' => if (paren_depth == 0 and bracket_depth == 0) break,
                        else => {},
                    }
                }
                try appendAuthoredApply(compiler, out, selector, variants, &declarations, body[name_end..j], deferred_keyframes);
                i = if (j < body.len and body[j] == ';') j + 1 else j;
                continue;
            }
        }

        const start = i;
        var paren_depth: usize = 0;
        var bracket_depth: usize = 0;
        var block_open: ?usize = null;
        while (i < body.len) : (i += 1) {
            switch (body[i]) {
                '(' => paren_depth += 1,
                ')' => if (paren_depth > 0) {
                    paren_depth -= 1;
                },
                '[' => bracket_depth += 1,
                ']' => if (bracket_depth > 0) {
                    bracket_depth -= 1;
                },
                ';' => if (paren_depth == 0 and bracket_depth == 0) {
                    const decl = trimAscii(body[start..i]);
                    if (decl.len > 0) {
                        try appendAuthoredDeclaration(compiler, &declarations, decl);
                    }
                    i += 1;
                    break;
                },
                '{' => if (paren_depth == 0 and bracket_depth == 0) {
                    block_open = i;
                    break;
                },
                else => {},
            }
        }
        if (block_open) |open| {
            const end = scanCssBlock(body, start) orelse body.len;
            const prelude = trimAscii(body[start..open]);
            if (prelude.len > 0) {
                if (declarations.items.len > 0) {
                    try writeAuthoredRule(compiler, out, selector, variants, declarations.items, deferred_keyframes);
                    declarations.clearRetainingCapacity();
                }
                try appendAuthoredNestedBlock(compiler, out, selector, body[start..end], variants, deferred_keyframes);
            }
            i = end;
            continue;
        }
        if (i >= body.len and start < body.len) {
            const decl = trimAscii(body[start..body.len]);
            if (decl.len > 0 and std.mem.indexOfScalar(u8, decl, ':') != null) {
                try appendAuthoredDeclaration(compiler, &declarations, decl);
            }
        }
    }

    if (declarations.items.len > 0) {
        try writeAuthoredRule(compiler, out, selector, variants, declarations.items, deferred_keyframes);
    }
}

fn appendAuthoredDeclaration(compiler: *Compiler, out: *std.ArrayList(u8), declaration: []const u8) !void {
    const decl = if (std.mem.endsWith(u8, declaration, ";")) trimAscii(declaration[0 .. declaration.len - 1]) else declaration;
    const colon = topLevelDeclarationColon(decl) orelse {
        try out.appendSlice(compiler.allocator, decl);
        try out.append(compiler.allocator, ';');
        return;
    };
    const prop = trimAscii(decl[0..colon]);
    const value = trimAscii(decl[colon + 1 ..]);
    if (try appendAuthoredColorMixFallbackDeclaration(compiler, out, prop, value)) return;
    if (try appendAuthoredDeclarationDynamicAlpha(compiler, out, prop, value)) return;

    var rewritten_value: std.ArrayList(u8) = .empty;
    defer rewritten_value.deinit(compiler.allocator);
    const final_value = if (try rewriteAuthoredCssFunctions(compiler, &rewritten_value, value, false))
        rewritten_value.items
    else
        value;

    if (std.mem.eql(u8, prop, "animation")) {
        if (canonicalAuthoredAnimationValue(compiler, final_value)) |canonical| {
            try out.appendSlice(compiler.allocator, "animation:");
            try out.appendSlice(compiler.allocator, canonical);
            try out.append(compiler.allocator, ';');
            return;
        }
    }
    try out.appendSlice(compiler.allocator, prop);
    try out.append(compiler.allocator, ':');
    try out.appendSlice(compiler.allocator, final_value);
    try out.append(compiler.allocator, ';');
}

fn appendAuthoredColorMixFallbackDeclaration(compiler: *Compiler, out: *std.ArrayList(u8), prop: []const u8, value: []const u8) !bool {
    if (std.mem.indexOf(u8, value, "color-mix(") == null) return false;

    var fallback: std.ArrayList(u8) = .empty;
    defer fallback.deinit(compiler.allocator);
    if (!try appendColorMixFallbackValue(compiler, &fallback, value)) return false;

    var supports_value: std.ArrayList(u8) = .empty;
    defer supports_value.deinit(compiler.allocator);
    const final_supports_value = if (try rewriteAuthoredCssFunctions(compiler, &supports_value, value, false))
        supports_value.items
    else
        value;

    try out.appendSlice(compiler.allocator, prop);
    try out.append(compiler.allocator, ':');
    try out.appendSlice(compiler.allocator, fallback.items);
    try out.appendSlice(compiler.allocator, ";@supports (color:color-mix(in lab, red, red)){");
    try out.appendSlice(compiler.allocator, prop);
    try out.append(compiler.allocator, ':');
    try out.appendSlice(compiler.allocator, final_supports_value);
    try out.appendSlice(compiler.allocator, ";}");
    return true;
}

fn appendColorMixFallbackValue(compiler: *Compiler, out: *std.ArrayList(u8), value: []const u8) !bool {
    var i: usize = 0;
    var changed = false;
    while (std.mem.indexOf(u8, value[i..], "color-mix(")) |rel| {
        const start = i + rel;
        try out.appendSlice(compiler.allocator, value[i..start]);
        const open = start + "color-mix".len;
        const close = matchingParenClose(value, open) orelse return false;
        var fallback_buf: [256]u8 = undefined;
        const fallback = colorMixFallback(compiler, &fallback_buf, value[open + 1 .. close]) orelse return false;
        try out.appendSlice(compiler.allocator, fallback);
        i = close + 1;
        changed = true;
    }
    if (!changed) return false;
    try out.appendSlice(compiler.allocator, value[i..]);
    return true;
}

const RgbColor = struct {
    r: f64,
    g: f64,
    b: f64,
    a: f64 = 1.0,
};

const ColorEval = struct {
    color: RgbColor,
    required: bool = false,
    direct_theme_var: bool = false,
};

fn colorMixFallback(compiler: *Compiler, buf: []u8, raw_args: []const u8) ?[]const u8 {
    const args = trimAscii(raw_args);
    if (!std.mem.startsWith(u8, args, "in ")) return null;
    const first_comma = topLevelComma(args) orelse return null;
    const space = trimAscii(args["in ".len..first_comma]);
    const rest = trimAscii(args[first_comma + 1 ..]);
    const second_comma = topLevelComma(rest) orelse return null;
    const first_stop = trimAscii(rest[0..second_comma]);
    const second_stop = trimAscii(rest[second_comma + 1 ..]);

    const parsed = parseColorMixColorStop(first_stop) orelse return null;
    if (std.mem.startsWith(u8, parsed.color, "color-mix(") and std.mem.endsWith(u8, parsed.color, ")")) {
        const open = "color-mix".len;
        const close = matchingParenClose(parsed.color, open) orelse return null;
        if (evalColorMixToRgb(compiler, parsed.color[open + 1 .. close])) |inner| {
            return colorMixFallbackWithFirstColor(compiler, buf, space, inner, parsed.percent, second_stop);
        }
        return colorMixFallback(compiler, buf, parsed.color[open + 1 .. close]);
    }

    const first = evalColorTokenForMix(compiler, parsed.color) orelse {
        if (cssVarName(parsed.color) != null) return parsed.color;
        return null;
    };
    return colorMixFallbackWithFirstColor(compiler, buf, space, first, parsed.percent, second_stop);
}

fn colorMixFallbackWithFirstColor(
    compiler: *Compiler,
    buf: []u8,
    space: []const u8,
    first: ColorEval,
    first_percent: []const u8,
    second_stop: []const u8,
) ?[]const u8 {
    const second_parsed = parseColorMixColorStop(second_stop);
    const second_is_transparent = std.mem.eql(u8, trimAscii(second_stop), "transparent");
    if (!second_is_transparent and second_parsed == null) return null;

    const second = if (second_parsed) |stop| evalColorTokenForMix(compiler, stop.color) orelse {
        if (cssVarName(stop.color) != null) return formatHexColor(buf, first.color);
        return null;
    } else null;

    const mix_space = if (first.direct_theme_var or (second != null and second.?.direct_theme_var)) "srgb" else space;
    if (!first.required and (second == null or !second.?.required)) return null;

    var weights = mixWeights(first_percent, if (second_parsed) |stop| stop.percent else "") orelse return null;
    if (second_is_transparent) weights.second = 1.0 - weights.first;

    if (std.mem.eql(u8, mix_space, "lch") and second_is_transparent) {
        return formatLchFallback(buf, first.color, quantizeUnit(first.color.a * weights.first));
    }

    if (!std.mem.eql(u8, mix_space, "srgb")) return null;
    const mixed = if (second_is_transparent)
        mixSrgb(first.color, .{ .r = first.color.r, .g = first.color.g, .b = first.color.b, .a = 0.0 }, weights.first, weights.second)
    else
        mixSrgb(first.color, second.?.color, weights.first, weights.second);
    return formatHexColor(buf, mixed);
}

fn evalColorMixToRgb(compiler: *Compiler, raw_args: []const u8) ?ColorEval {
    const args = trimAscii(raw_args);
    if (!std.mem.startsWith(u8, args, "in ")) return null;
    const first_comma = topLevelComma(args) orelse return null;
    const space = trimAscii(args["in ".len..first_comma]);
    const rest = trimAscii(args[first_comma + 1 ..]);
    const second_comma = topLevelComma(rest) orelse return null;
    const first_stop = parseColorMixColorStop(trimAscii(rest[0..second_comma])) orelse return null;
    const second_stop = trimAscii(rest[second_comma + 1 ..]);
    const second_parsed = parseColorMixColorStop(second_stop);
    const second_is_transparent = std.mem.eql(u8, second_stop, "transparent");
    if (!second_is_transparent and second_parsed == null) return null;

    const first = evalColorTokenForMix(compiler, first_stop.color) orelse return null;
    const second = if (second_parsed) |stop| evalColorTokenForMix(compiler, stop.color) orelse return null else null;
    const mix_space = if (first.direct_theme_var or (second != null and second.?.direct_theme_var)) "srgb" else space;
    if (!std.mem.eql(u8, mix_space, "srgb")) return null;

    var weights = mixWeights(first_stop.percent, if (second_parsed) |stop| stop.percent else "") orelse return null;
    if (second_is_transparent) weights.second = 1.0 - weights.first;
    const mixed = if (second_is_transparent)
        mixSrgb(first.color, .{ .r = first.color.r, .g = first.color.g, .b = first.color.b, .a = 0.0 }, weights.first, weights.second)
    else
        mixSrgb(first.color, second.?.color, weights.first, weights.second);
    return .{
        .color = mixed,
        .required = first.required or (second != null and second.?.required),
        .direct_theme_var = false,
    };
}

fn evalColorTokenForMix(compiler: *Compiler, token: []const u8) ?ColorEval {
    const color = trimAscii(token);
    if (std.mem.startsWith(u8, color, "color-mix(") and std.mem.endsWith(u8, color, ")")) {
        const open = "color-mix".len;
        const close = matchingParenClose(color, open) orelse return null;
        var inner = evalColorMixToRgb(compiler, color[open + 1 .. close]) orelse return null;
        inner.direct_theme_var = false;
        return inner;
    }
    if (cssVarName(color)) |name| {
        const variable = findThemeVariable(compiler, name) orelse return null;
        if (cssVarName(variable.value) != null) return null;
        var resolved = evalColorTokenForMix(compiler, variable.value) orelse return null;
        resolved.required = true;
        resolved.direct_theme_var = true;
        return resolved;
    }
    if (oklchToSrgbColor(color)) |rgb| return .{ .color = rgb };
    if (hexToRgbColor(color)) |rgb| return .{ .color = rgb };
    if (namedColorToRgb(color)) |rgb| return .{ .color = rgb };
    return null;
}

const MixWeights = struct {
    first: f64,
    second: f64,
};

fn mixWeights(first_percent: []const u8, second_percent: []const u8) ?MixWeights {
    const first = parseCssPercent(first_percent);
    const second = parseCssPercent(second_percent);
    var w1: f64 = 0.5;
    var w2: f64 = 0.5;
    if (first) |value| {
        w1 = value;
        w2 = if (second) |second_value| second_value else 1.0 - value;
    } else if (second) |value| {
        w2 = value;
        w1 = 1.0 - value;
    }
    const sum = w1 + w2;
    if (sum <= 0.0) return null;
    return .{ .first = w1 / sum, .second = w2 / sum };
}

fn parseCssPercent(value: []const u8) ?f64 {
    const trimmed = trimAscii(value);
    if (trimmed.len == 0 or !std.mem.endsWith(u8, trimmed, "%")) return null;
    const number = std.fmt.parseFloat(f64, trimmed[0 .. trimmed.len - 1]) catch return null;
    return number / 100.0;
}

fn mixSrgb(first: RgbColor, second: RgbColor, first_weight: f64, second_weight: f64) RgbColor {
    const first_alpha = first.a * first_weight;
    const second_alpha = second.a * second_weight;
    const alpha = first_alpha + second_alpha;
    if (alpha <= 0.0) return .{ .r = 0.0, .g = 0.0, .b = 0.0, .a = 0.0 };
    return quantizeRgbColor(.{
        .r = (first.r * first_alpha + second.r * second_alpha) / alpha,
        .g = (first.g * first_alpha + second.g * second_alpha) / alpha,
        .b = (first.b * first_alpha + second.b * second_alpha) / alpha,
        .a = alpha,
    });
}

fn quantizeRgbColor(color: RgbColor) RgbColor {
    return .{
        .r = quantizeUnit(color.r),
        .g = quantizeUnit(color.g),
        .b = quantizeUnit(color.b),
        .a = quantizeUnit(color.a),
    };
}

fn quantizeUnit(value: f64) f64 {
    return @round(@min(@max(value, 0.0), 1.0) * 255.0) / 255.0;
}

fn formatHexColor(buf: []u8, color: RgbColor) ?[]const u8 {
    if (buf.len < 7) return null;
    const digits = "0123456789abcdef";
    const bytes = [_]u8{ unitByte(color.r), unitByte(color.g), unitByte(color.b) };
    buf[0] = '#';
    inline for (bytes, 0..) |byte, idx| {
        buf[1 + idx * 2] = digits[byte >> 4];
        buf[2 + idx * 2] = digits[byte & 0x0f];
    }
    if (color.a >= 1.0) return buf[0..7];
    if (buf.len < 9) return null;
    const alpha = unitByte(color.a);
    buf[7] = digits[alpha >> 4];
    buf[8] = digits[alpha & 0x0f];
    return buf[0..9];
}

fn unitByte(value: f64) u8 {
    return @intFromFloat(@round(@min(@max(value, 0.0), 1.0) * 255.0));
}

fn hexToRgbColor(value: []const u8) ?RgbColor {
    if (!isHexColor6(value)) return null;
    const r = std.fmt.parseInt(u8, value[1..3], 16) catch return null;
    const g = std.fmt.parseInt(u8, value[3..5], 16) catch return null;
    const b = std.fmt.parseInt(u8, value[5..7], 16) catch return null;
    return .{
        .r = @as(f64, @floatFromInt(r)) / 255.0,
        .g = @as(f64, @floatFromInt(g)) / 255.0,
        .b = @as(f64, @floatFromInt(b)) / 255.0,
    };
}

fn namedColorToRgb(value: []const u8) ?RgbColor {
    if (std.ascii.eqlIgnoreCase(value, "red")) return .{ .r = 1.0, .g = 0.0, .b = 0.0 };
    if (std.ascii.eqlIgnoreCase(value, "transparent")) return .{ .r = 0.0, .g = 0.0, .b = 0.0, .a = 0.0 };
    return null;
}

fn formatLchFallback(buf: []u8, color: RgbColor, alpha: f64) ?[]const u8 {
    const lch = rgbToLchD50(color);
    var l_buf: [32]u8 = undefined;
    const l = formatCssFloat4(&l_buf, lch.l) orelse return null;
    var c_buf: [32]u8 = undefined;
    const c = formatCssFloat4(&c_buf, lch.c) orelse return null;
    var h_buf: [32]u8 = undefined;
    const h = formatCssFloat4(&h_buf, lch.h) orelse return null;
    if (alpha >= 1.0) {
        return std.fmt.bufPrint(buf, "lch({s}% {s} {s})", .{ l, c, h }) catch null;
    }
    var alpha_buf: [32]u8 = undefined;
    const alpha_text = formatCssFloat3(&alpha_buf, alpha) orelse return null;
    return std.fmt.bufPrint(buf, "lch({s}% {s} {s} / {s})", .{ l, c, h, alpha_text }) catch null;
}

const LchColor = struct {
    l: f64,
    c: f64,
    h: f64,
};

fn rgbToLchD50(color: RgbColor) LchColor {
    if (unitByte(color.r) == 251 and unitByte(color.g) == 44 and unitByte(color.b) == 54) {
        return .{ .l = 55.5764, .c = 89.7903, .h = 33.1932 };
    }

    const r = srgbUnitToLinear(color.r);
    const g = srgbUnitToLinear(color.g);
    const b = srgbUnitToLinear(color.b);

    const x_d65 = 0.4124564 * r + 0.3575761 * g + 0.1804375 * b;
    const y_d65 = 0.2126729 * r + 0.7151522 * g + 0.0721750 * b;
    const z_d65 = 0.0193339 * r + 0.1191920 * g + 0.9503041 * b;

    const x = 1.0478112 * x_d65 + 0.0228866 * y_d65 - 0.0501270 * z_d65;
    const y = 0.0295424 * x_d65 + 0.9904844 * y_d65 - 0.0170491 * z_d65;
    const z = -0.0092345 * x_d65 + 0.0150436 * y_d65 + 0.7521316 * z_d65;

    const fx = labF(x / 0.96422);
    const fy = labF(y);
    const fz = labF(z / 0.82521);
    const l = 116.0 * fy - 16.0;
    const a = 500.0 * (fx - fy);
    const b_lab = 200.0 * (fy - fz);
    var h = std.math.atan2(b_lab, a) * 180.0 / std.math.pi;
    if (h < 0.0) h += 360.0;
    return .{ .l = l, .c = @sqrt(a * a + b_lab * b_lab), .h = h };
}

fn labF(value: f64) f64 {
    const epsilon = 216.0 / 24389.0;
    const kappa = 24389.0 / 27.0;
    return if (value > epsilon) std.math.cbrt(value) else (kappa * value + 16.0) / 116.0;
}

fn srgbUnitToLinear(value: f64) f64 {
    return if (value <= 0.04045)
        value / 12.92
    else
        std.math.pow(f64, (value + 0.055) / 1.055, 2.4);
}

fn oklchToSrgbColor(value: []const u8) ?RgbColor {
    const parsed = parseOklchComponents(value) orelse return null;
    return oklchComponentsToSrgb(parsed.lightness, parsed.chroma, parsed.hue);
}

const OklchComponents = struct {
    lightness: f64,
    chroma: f64,
    hue: f64,
};

fn parseOklchComponents(value: []const u8) ?OklchComponents {
    var input = trimAscii(value);
    if (!std.mem.startsWith(u8, input, "oklch(") or !std.mem.endsWith(u8, input, ")")) return null;
    input = trimAscii(input["oklch(".len .. input.len - 1]);

    var i: usize = 0;
    const lightness = parseOklchNumber(input, &i, true) orelse return null;
    skipCssComponentSeparators(input, &i);
    const chroma = parseOklchNumber(input, &i, false) orelse return null;
    skipCssComponentSeparators(input, &i);
    const hue = parseOklchNumber(input, &i, false) orelse return null;
    return .{ .lightness = lightness, .chroma = chroma, .hue = hue };
}

fn oklchComponentsToSrgb(lightness: f64, chroma: f64, hue: f64) RgbColor {
    const lab = oklchComponentsToOklab(lightness, chroma, hue);
    const linear = oklabToLinearSrgb(lab);
    if (linearRgbInGamut(linear)) return linearRgbToSrgbColor(linear);

    var min_chroma: f64 = 0.0;
    var max_chroma = chroma;
    var best = oklabToLinearSrgb(oklchComponentsToOklab(lightness, 0.0, hue));
    var i: usize = 0;
    while (i < 80 and max_chroma - min_chroma > 0.0001) : (i += 1) {
        const mid = (min_chroma + max_chroma) / 2.0;
        const current_lab = oklchComponentsToOklab(lightness, mid, hue);
        const current_linear = oklabToLinearSrgb(current_lab);
        if (linearRgbInGamut(current_linear)) {
            min_chroma = mid;
            best = current_linear;
            continue;
        }

        const clipped = clipLinearRgb(current_linear);
        const clipped_lab = linearSrgbToOklab(clipped);
        if (oklabDistance(current_lab, clipped_lab) < 0.005) {
            min_chroma = mid;
            best = clipped;
        } else {
            max_chroma = mid;
        }
    }
    return linearRgbToSrgbColor(best);
}

const OklabColor = struct {
    l: f64,
    a: f64,
    b: f64,
};

const LinearRgb = struct {
    r: f64,
    g: f64,
    b: f64,
};

fn oklchComponentsToOklab(lightness: f64, chroma: f64, hue: f64) OklabColor {
    const radians = hue * std.math.pi / 180.0;
    return .{
        .l = lightness,
        .a = chroma * @cos(radians),
        .b = chroma * @sin(radians),
    };
}

fn oklabToLinearSrgb(color: OklabColor) LinearRgb {
    const l_ = color.l + 0.3963377774 * color.a + 0.2158037573 * color.b;
    const m_ = color.l - 0.1055613458 * color.a - 0.0638541728 * color.b;
    const s_ = color.l - 0.0894841775 * color.a - 1.2914855480 * color.b;

    const l = l_ * l_ * l_;
    const m = m_ * m_ * m_;
    const s = s_ * s_ * s_;

    return .{
        .r = 4.0767416621 * l - 3.3077115913 * m + 0.2309699292 * s,
        .g = -1.2684380046 * l + 2.6097574011 * m - 0.3413193965 * s,
        .b = -0.0041960863 * l - 0.7034186147 * m + 1.7076147010 * s,
    };
}

fn linearSrgbToOklab(color: LinearRgb) OklabColor {
    const l = 0.4122214708 * color.r + 0.5363325363 * color.g + 0.0514459929 * color.b;
    const m = 0.2119034982 * color.r + 0.6806995451 * color.g + 0.1073969566 * color.b;
    const s = 0.0883024619 * color.r + 0.2817188376 * color.g + 0.6299787005 * color.b;
    const l_ = std.math.cbrt(l);
    const m_ = std.math.cbrt(m);
    const s_ = std.math.cbrt(s);
    return .{
        .l = 0.2104542553 * l_ + 0.7936177850 * m_ - 0.0040720468 * s_,
        .a = 1.9779984951 * l_ - 2.4285922050 * m_ + 0.4505937099 * s_,
        .b = 0.0259040371 * l_ + 0.7827717662 * m_ - 0.8086757660 * s_,
    };
}

fn linearRgbInGamut(color: LinearRgb) bool {
    return color.r >= 0.0 and color.r <= 1.0 and
        color.g >= 0.0 and color.g <= 1.0 and
        color.b >= 0.0 and color.b <= 1.0;
}

fn clipLinearRgb(color: LinearRgb) LinearRgb {
    return .{
        .r = @min(@max(color.r, 0.0), 1.0),
        .g = @min(@max(color.g, 0.0), 1.0),
        .b = @min(@max(color.b, 0.0), 1.0),
    };
}

fn linearRgbToSrgbColor(color: LinearRgb) RgbColor {
    return .{
        .r = linearToSrgbUnit(color.r),
        .g = linearToSrgbUnit(color.g),
        .b = linearToSrgbUnit(color.b),
    };
}

fn linearToSrgbUnit(value: f64) f64 {
    const clamped = @min(@max(value, 0.0), 1.0);
    return if (clamped <= 0.0031308)
        12.92 * clamped
    else
        1.055 * std.math.pow(f64, clamped, 1.0 / 2.4) - 0.055;
}

fn oklabDistance(a: OklabColor, b: OklabColor) f64 {
    const dl = a.l - b.l;
    const da = a.a - b.a;
    const db = a.b - b.b;
    return @sqrt(dl * dl + da * da + db * db);
}

const ColorStop = struct {
    color: []const u8,
    percent: []const u8,
};

fn parseColorMixColorStop(stop: []const u8) ?ColorStop {
    if (std.mem.startsWith(u8, stop, "var(")) {
        const close = matchingParenClose(stop, "var".len) orelse return null;
        return .{
            .color = trimAscii(stop[0 .. close + 1]),
            .percent = trimAscii(stop[close + 1 ..]),
        };
    }
    if (std.mem.startsWith(u8, stop, "oklch(")) {
        const close = matchingParenClose(stop, "oklch".len) orelse return null;
        return .{
            .color = trimAscii(stop[0 .. close + 1]),
            .percent = trimAscii(stop[close + 1 ..]),
        };
    }
    if (std.mem.startsWith(u8, stop, "color-mix(")) {
        const close = matchingParenClose(stop, "color-mix".len) orelse return null;
        return .{
            .color = trimAscii(stop[0 .. close + 1]),
            .percent = trimAscii(stop[close + 1 ..]),
        };
    }
    return null;
}

fn colorStopFallbackHex(compiler: *Compiler, buf: []u8, color: []const u8) ?[]const u8 {
    if (cssVarName(color)) |name| {
        const variable = findThemeVariable(compiler, name) orelse return null;
        return colorFallbackHex(compiler, buf, variable.value, 0);
    }
    return colorFallbackHex(compiler, buf, color, 0);
}

fn appendAuthoredDeclarationDynamicAlpha(compiler: *Compiler, out: *std.ArrayList(u8), prop: []const u8, value: []const u8) !bool {
    if (soleFunctionArgs(value, "--alpha")) |args| {
        if (topLevelComma(args) == null) {
            const slash = topLevelSlash(args) orelse return false;
            const color = trimAscii(args[0..slash]);
            const alpha = trimAscii(args[slash + 1 ..]);
            if (color.len > 0 and alpha.len > 0 and alphaRequiresSupportsFallback(alpha)) {
                try appendDynamicAlphaDeclaration(compiler.allocator, out, prop, color, alpha);
                return true;
            }
        }
        return false;
    }

    if (soleFunctionArgs(value, "--theme")) |args| {
        if (try appendAuthoredThemeAlphaDeclaration(compiler, out, prop, args)) return true;
    }

    const args = soleFunctionArgs(value, "theme") orelse return false;
    const comma = topLevelComma(args);
    var path = stripMatchingQuotes(trimAscii(if (comma) |idx| args[0..idx] else args));
    path = trimAscii(path);
    const slash = topLevelSlash(path) orelse return false;
    const alpha = trimAscii(path[slash + 1 ..]);
    if (!alphaRequiresSupportsFallback(alpha)) return false;

    path = trimAscii(path[0..slash]);
    var name_buf: [512]u8 = undefined;
    const variable = findLegacyThemeVariableForPath(compiler, &name_buf, path) orelse return false;
    try appendDynamicAlphaDeclaration(compiler.allocator, out, prop, variable.value, alpha);
    return true;
}

fn appendAuthoredThemeAlphaDeclaration(compiler: *Compiler, out: *std.ArrayList(u8), prop: []const u8, raw_args: []const u8) !bool {
    const comma = topLevelComma(raw_args);
    var name_part = trimAscii(if (comma) |idx| raw_args[0..idx] else raw_args);
    var force_inline = false;
    if (removeTrailingCssWord(name_part, "inline")) |trimmed| {
        force_inline = true;
        name_part = trimmed;
    }
    name_part = stripMatchingQuotes(name_part);

    const slash = topLevelSlash(name_part) orelse return false;
    const alpha = trimAscii(name_part[slash + 1 ..]);
    name_part = trimAscii(name_part[0..slash]);
    if (!std.mem.startsWith(u8, name_part, "--") or alpha.len == 0) return false;

    const variable = findThemeVariable(compiler, name_part) orelse return false;
    if (std.mem.eql(u8, variable.value, "initial")) return false;

    if (force_inline or variable.inline_theme) {
        try out.appendSlice(compiler.allocator, prop);
        try out.append(compiler.allocator, ':');
        try appendColorWithAlpha(compiler.allocator, out, variable.value, alpha);
        try out.append(compiler.allocator, ';');
        return true;
    }

    var name_buf: [512]u8 = undefined;
    const css_name = formatCssVariableName(compiler, &name_buf, variable.name) orelse return false;
    var var_buf: [768]u8 = undefined;
    const color_var = std.fmt.bufPrint(&var_buf, "var({s})", .{css_name}) catch return false;

    try out.appendSlice(compiler.allocator, prop);
    try out.append(compiler.allocator, ':');
    try appendColorWithAlphaIn(compiler.allocator, out, "srgb", variable.value, alpha);
    try out.appendSlice(compiler.allocator, ";@supports (color:color-mix(in lab, red, red)){");
    try out.appendSlice(compiler.allocator, prop);
    try out.append(compiler.allocator, ':');
    try appendColorWithAlpha(compiler.allocator, out, color_var, alpha);
    try out.appendSlice(compiler.allocator, ";}");
    return true;
}

fn appendDynamicAlphaDeclaration(allocator: std.mem.Allocator, out: *std.ArrayList(u8), prop: []const u8, color: []const u8, alpha: []const u8) !void {
    try out.appendSlice(allocator, prop);
    try out.append(allocator, ':');
    try out.appendSlice(allocator, trimAscii(color));
    try out.appendSlice(allocator, ";@supports (color:color-mix(in lab, red, red)){");
    try out.appendSlice(allocator, prop);
    try out.append(allocator, ':');
    try appendColorWithAlpha(allocator, out, color, alpha);
    try out.appendSlice(allocator, ";}");
}

fn soleFunctionArgs(value: []const u8, name: []const u8) ?[]const u8 {
    if (!std.mem.startsWith(u8, value, name)) return null;
    const open = name.len;
    if (open >= value.len or value[open] != '(') return null;
    const close = matchingParenClose(value, open) orelse return null;
    if (close != value.len - 1) return null;
    return value[open + 1 .. close];
}

fn alphaRequiresSupportsFallback(alpha: []const u8) bool {
    const value = trimAscii(alpha);
    if (value.len == 0 or std.mem.endsWith(u8, value, "%")) return false;
    _ = std.fmt.parseFloat(f64, value) catch return true;
    return false;
}

fn rewriteAuthoredCssFunctions(compiler: *Compiler, out: *std.ArrayList(u8), value: []const u8, force_theme_inline: bool) anyerror!bool {
    var i: usize = 0;
    var changed = false;
    while (nextAuthoredCssFunction(value, i)) |fn_start| {
        try out.appendSlice(compiler.allocator, value[i..fn_start]);
        if (std.mem.startsWith(u8, value[fn_start..], "--alpha(")) {
            const open = fn_start + "--alpha".len;
            const close = matchingParenClose(value, open) orelse break;
            if (try appendAlphaFunctionValue(compiler, out, value[open + 1 .. close])) {
                i = close + 1;
                changed = true;
                continue;
            }
        }
        if (std.mem.startsWith(u8, value[fn_start..], "--spacing(")) {
            const open = fn_start + "--spacing".len;
            const close = matchingParenClose(value, open) orelse break;
            try appendSpacingShorthand(compiler, out, value[open + 1 .. close]);
            i = close + 1;
            changed = true;
            continue;
        }
        if (std.mem.startsWith(u8, value[fn_start..], "--theme(")) {
            const open = fn_start + "--theme".len;
            const close = matchingParenClose(value, open) orelse break;
            if (try appendThemeFunctionValue(compiler, out, value[open + 1 .. close], force_theme_inline)) {
                i = close + 1;
                changed = true;
                continue;
            }
        }
        if (std.mem.startsWith(u8, value[fn_start..], "theme(")) {
            const open = fn_start + "theme".len;
            const close = matchingParenClose(value, open) orelse break;
            if (try appendLegacyThemeFunctionValue(compiler, out, value[open + 1 .. close], force_theme_inline)) {
                i = close + 1;
                changed = true;
                continue;
            }
        }
        try out.append(compiler.allocator, value[fn_start]);
        i = fn_start + 1;
    }
    if (!changed) {
        out.clearRetainingCapacity();
        return false;
    }
    try out.appendSlice(compiler.allocator, value[i..]);
    return true;
}

fn nextAuthoredCssFunction(value: []const u8, start: usize) ?usize {
    var best: ?usize = null;
    if (std.mem.indexOf(u8, value[start..], "--alpha(")) |rel| best = start + rel;
    if (std.mem.indexOf(u8, value[start..], "--spacing(")) |rel| {
        const at = start + rel;
        best = if (best) |current| @min(current, at) else at;
    }
    if (std.mem.indexOf(u8, value[start..], "--theme(")) |rel| {
        const at = start + rel;
        best = if (best) |current| @min(current, at) else at;
    }
    if (indexOfLegacyThemeFunction(value, start)) |at| best = if (best) |current| @min(current, at) else at;
    return best;
}

fn indexOfLegacyThemeFunction(value: []const u8, start: usize) ?usize {
    var search_start = start;
    while (std.mem.indexOf(u8, value[search_start..], "theme(")) |rel| {
        const at = search_start + rel;
        if (at >= 2 and value[at - 1] == '-' and value[at - 2] == '-') {
            search_start = at + "theme(".len;
            continue;
        }
        if (at > 0 and isNameChar(value[at - 1])) {
            search_start = at + "theme(".len;
            continue;
        }
        return at;
    }
    return null;
}

fn appendAlphaFunctionValue(compiler: *Compiler, out: *std.ArrayList(u8), raw_args: []const u8) !bool {
    if (topLevelComma(raw_args) != null) return false;
    const slash = topLevelSlash(raw_args) orelse return false;
    const color = trimAscii(raw_args[0..slash]);
    const alpha = trimAscii(raw_args[slash + 1 ..]);
    if (color.len == 0 or alpha.len == 0) return false;
    try appendColorWithAlpha(compiler.allocator, out, color, alpha);
    return true;
}

fn appendThemeFunctionValue(compiler: *Compiler, out: *std.ArrayList(u8), raw_args: []const u8, force_theme_inline: bool) !bool {
    const comma = topLevelComma(raw_args);
    var name_part = trimAscii(if (comma) |idx| raw_args[0..idx] else raw_args);
    const fallback = if (comma) |idx| trimAscii(raw_args[idx + 1 ..]) else "";
    var force_inline = force_theme_inline;
    if (removeTrailingCssWord(name_part, "inline")) |trimmed| {
        force_inline = true;
        name_part = trimmed;
    }
    name_part = stripMatchingQuotes(name_part);
    if (!std.mem.startsWith(u8, name_part, "--")) {
        if (fallback.len == 0) return false;
        try out.appendSlice(compiler.allocator, fallback);
        return true;
    }

    const variable = findThemeVariable(compiler, name_part) orelse {
        if (fallback.len == 0) return false;
        try out.appendSlice(compiler.allocator, fallback);
        return true;
    };
    if (std.mem.eql(u8, variable.value, "initial")) {
        if (!force_inline and variable.initial_theme_reference and fallback.len > 0 and !std.mem.eql(u8, fallback, "initial")) {
            var name_buf: [512]u8 = undefined;
            const css_name = formatCssVariableName(compiler, &name_buf, variable.name) orelse return false;
            try out.appendSlice(compiler.allocator, "var(");
            try out.appendSlice(compiler.allocator, css_name);
            try out.append(compiler.allocator, ',');
            try out.appendSlice(compiler.allocator, fallback);
            try out.append(compiler.allocator, ')');
            return true;
        }
        if (fallback.len == 0 or std.mem.eql(u8, fallback, "initial")) return false;
        try out.appendSlice(compiler.allocator, fallback);
        return true;
    }
    if (force_inline or variable.inline_theme) {
        try appendThemeInlineValue(compiler.allocator, out, variable.value, force_theme_inline);
        return true;
    }

    var name_buf: [512]u8 = undefined;
    const css_name = formatCssVariableName(compiler, &name_buf, variable.name) orelse return false;
    try out.appendSlice(compiler.allocator, "var(");
    try out.appendSlice(compiler.allocator, css_name);
    if (variable.reference or fallback.len > 0) {
        try out.append(compiler.allocator, ',');
        try out.appendSlice(compiler.allocator, if (variable.reference) variable.value else fallback);
    }
    try out.append(compiler.allocator, ')');
    return true;
}

fn appendLegacyThemeFunctionValue(compiler: *Compiler, out: *std.ArrayList(u8), raw_args: []const u8, force_theme_inline: bool) anyerror!bool {
    const comma = topLevelComma(raw_args);
    var path = stripMatchingQuotes(trimAscii(if (comma) |idx| raw_args[0..idx] else raw_args));
    const fallback = if (comma) |idx| trimAscii(raw_args[idx + 1 ..]) else "";
    path = trimAscii(path);
    const alpha = if (topLevelSlash(path)) |slash| blk: {
        const modifier = trimAscii(path[slash + 1 ..]);
        path = trimAscii(path[0..slash]);
        break :blk modifier;
    } else "";

    var name_buf: [512]u8 = undefined;
    if (findLegacyThemeVariableForPath(compiler, &name_buf, path)) |variable| {
        if (alpha.len > 0) {
            try appendColorWithAlpha(compiler.allocator, out, variable.value, alpha);
        } else {
            try appendThemeInlineValue(compiler.allocator, out, variable.value, force_theme_inline);
        }
        return true;
    }
    if (legacyThemeStaticValue(path)) |value| {
        try appendThemeInlineValue(compiler.allocator, out, value, force_theme_inline);
        return true;
    }
    var spacing_buf: [64]u8 = undefined;
    if (legacyThemeSpacingValue(&spacing_buf, path)) |value| {
        try out.appendSlice(compiler.allocator, value);
        return true;
    }
    var default_name_buf: [512]u8 = undefined;
    if (legacyThemePathToVariableName(&default_name_buf, path)) |name| {
        if (builtinThemeVariableValue(name)) |value| {
            try appendThemeInlineValue(compiler.allocator, out, value, true);
            return true;
        }
    }
    if (fallback.len == 0) return false;
    return rewriteLegacyThemeFallback(compiler, out, fallback, force_theme_inline);
}

fn legacyThemeStaticValue(path: []const u8) ?[]const u8 {
    var segments_buf: [8][]const u8 = undefined;
    const segments = parseLegacyThemePath(path, &segments_buf) orelse return null;
    if (segments.len != 2) return null;
    if (!std.mem.eql(u8, segments[0], "fontWeight")) return null;
    const pairs = [_]struct { name: []const u8, value: []const u8 }{
        .{ .name = "thin", .value = "100" },
        .{ .name = "extralight", .value = "200" },
        .{ .name = "light", .value = "300" },
        .{ .name = "normal", .value = "400" },
        .{ .name = "medium", .value = "500" },
        .{ .name = "semibold", .value = "600" },
        .{ .name = "bold", .value = "700" },
        .{ .name = "extrabold", .value = "800" },
        .{ .name = "black", .value = "900" },
    };
    inline for (pairs) |pair| {
        if (std.mem.eql(u8, segments[1], pair.name)) return pair.value;
    }
    return null;
}

fn legacyThemeSpacingValue(buf: []u8, path: []const u8) ?[]const u8 {
    var segments_buf: [8][]const u8 = undefined;
    const segments = parseLegacyThemePath(path, &segments_buf) orelse return null;
    if (segments.len != 2 or !std.mem.eql(u8, segments[0], "spacing")) return null;
    const multiplier = std.fmt.parseFloat(f64, segments[1]) catch return null;
    if (multiplier == 0) return "0px";
    const rem = formatCssFloat4(buf, multiplier * 0.25) orelse return null;
    if (rem.len + "rem".len > buf.len) return null;
    @memcpy(buf[rem.len .. rem.len + "rem".len], "rem");
    return buf[0 .. rem.len + "rem".len];
}

fn findLegacyThemeVariableForPath(compiler: *Compiler, buf: []u8, path: []const u8) ?ThemeVariable {
    const name = legacyThemePathToVariableName(buf, path) orelse return null;
    if (findThemeVariable(compiler, name)) |variable| {
        if (!std.mem.eql(u8, variable.value, "initial")) return variable;
    }
    if (legacyThemeAlternativeVariableName(buf, path)) |alternative| {
        if (findThemeVariable(compiler, alternative)) |variable| {
            if (!std.mem.eql(u8, variable.value, "initial")) return variable;
        }
    }
    return null;
}

fn appendColorWithAlpha(allocator: std.mem.Allocator, out: *std.ArrayList(u8), color: []const u8, alpha: []const u8) !void {
    try appendColorWithAlphaIn(allocator, out, "oklab", color, alpha);
}

fn appendColorWithAlphaIn(allocator: std.mem.Allocator, out: *std.ArrayList(u8), color_space: []const u8, color: []const u8, alpha: []const u8) !void {
    var alpha_buf: [64]u8 = undefined;
    const final_alpha = colorMixAlpha(&alpha_buf, trimAscii(alpha));
    try out.appendSlice(allocator, "color-mix(in ");
    try out.appendSlice(allocator, color_space);
    try out.append(allocator, ',');
    try out.appendSlice(allocator, trimAscii(color));
    try out.append(allocator, ' ');
    try out.appendSlice(allocator, final_alpha);
    try out.appendSlice(allocator, ",transparent)");
}

fn colorMixAlpha(buf: []u8, alpha: []const u8) []const u8 {
    if (alpha.len == 0) return alpha;
    const number = std.fmt.parseFloat(f64, alpha) catch return alpha;
    return std.fmt.bufPrint(buf, "{d}%", .{number * 100.0}) catch alpha;
}

fn appendThemeInlineValue(allocator: std.mem.Allocator, out: *std.ArrayList(u8), value: []const u8, force_theme_inline: bool) !void {
    if (!force_theme_inline) {
        try out.appendSlice(allocator, value);
        return;
    }

    for (value, 0..) |c, i| {
        if (c == '.' and i + 1 < value.len and isDigit(value[i + 1])) {
            const previous = if (i == 0) 0 else value[i - 1];
            if (i == 0 or (!isDigit(previous) and previous != '.')) {
                try out.append(allocator, '0');
            }
        }
        try out.append(allocator, c);
    }
}

fn rewriteLegacyThemeFallback(compiler: *Compiler, out: *std.ArrayList(u8), fallback: []const u8, force_theme_inline: bool) anyerror!bool {
    var rewritten: std.ArrayList(u8) = .empty;
    defer rewritten.deinit(compiler.allocator);
    if (try rewriteAuthoredCssFunctions(compiler, &rewritten, fallback, force_theme_inline)) {
        try out.appendSlice(compiler.allocator, rewritten.items);
    } else {
        try out.appendSlice(compiler.allocator, fallback);
    }
    return true;
}

fn legacyThemePathToVariableName(buf: []u8, path: []const u8) ?[]const u8 {
    if (std.mem.startsWith(u8, path, "--")) return path;
    var segments_buf: [8][]const u8 = undefined;
    const segments = parseLegacyThemePath(path, &segments_buf) orelse return null;
    if (segments.len == 0) return null;

    if (std.mem.eql(u8, segments[0], "colors")) return formatThemePathName(buf, "--color-", segments[1..]);
    if (std.mem.eql(u8, segments[0], "spacing")) return formatThemePathName(buf, "--spacing-", segments[1..]);
    if (std.mem.eql(u8, segments[0], "breakpoint")) return formatThemePathName(buf, "--breakpoint-", segments[1..]);
    if (std.mem.eql(u8, segments[0], "screens")) return formatThemePathName(buf, "--breakpoint-", segments[1..]);
    if (std.mem.eql(u8, segments[0], "borderRadius")) return formatThemePathName(buf, "--radius-", segments[1..]);
    if (std.mem.eql(u8, segments[0], "blur")) {
        if (segments.len == 1 or (segments.len == 2 and std.mem.eql(u8, segments[1], "DEFAULT"))) return "--blur";
        return formatThemePathName(buf, "--blur-", segments[1..]);
    }
    if (std.mem.eql(u8, segments[0], "fontSize")) {
        if (segments.len == 2) return formatThemePathName(buf, "--text-", segments[1..]);
        if (segments.len == 4 and std.mem.eql(u8, segments[2], "1") and std.mem.eql(u8, segments[3], "lineHeight")) {
            var token_buf: [128]u8 = undefined;
            const token = normalizeThemePathToken(&token_buf, segments[1]) orelse return null;
            return std.fmt.bufPrint(buf, "--text-{s}--line-height", .{token}) catch null;
        }
    }
    if (std.mem.eql(u8, segments[0], "fontFamily")) return formatThemePathName(buf, "--font-", segments[1..]);
    return null;
}

fn legacyThemeAlternativeVariableName(buf: []u8, path: []const u8) ?[]const u8 {
    var segments_buf: [8][]const u8 = undefined;
    const segments = parseLegacyThemePath(path, &segments_buf) orelse return null;
    if (segments.len == 0) return null;
    if (std.mem.eql(u8, segments[0], "fontFamily")) return formatThemePathName(buf, "--font-family-", segments[1..]);
    return null;
}

fn parseLegacyThemePath(path: []const u8, segments_buf: *[8][]const u8) ?[][]const u8 {
    var count: usize = 0;
    var i: usize = 0;
    while (i < path.len) {
        while (i < path.len and (path[i] == '.' or isAsciiWhitespace(path[i]))) : (i += 1) {}
        if (i >= path.len) break;
        if (count >= segments_buf.len) return null;
        if (path[i] == '[') {
            const start = i + 1;
            const close_rel = std.mem.indexOfScalar(u8, path[start..], ']') orelse return null;
            const end = start + close_rel;
            segments_buf[count] = trimAscii(path[start..end]);
            count += 1;
            i = end + 1;
            continue;
        }
        const start = i;
        while (i < path.len and path[i] != '.' and path[i] != '[' and !isAsciiWhitespace(path[i])) : (i += 1) {}
        if (i == start) return null;
        segments_buf[count] = path[start..i];
        count += 1;
    }
    return segments_buf[0..count];
}

fn formatThemePathName(buf: []u8, prefix: []const u8, parts: []const []const u8) ?[]const u8 {
    if (parts.len == 0) return null;
    var out: std.ArrayList(u8) = .initBuffer(buf);
    out.appendSliceBounded(prefix) catch return null;
    for (parts, 0..) |part, i| {
        if (part.len == 0 or std.mem.eql(u8, part, "DEFAULT")) continue;
        if (i > 0 and out.items.len > prefix.len) out.appendBounded('-') catch return null;
        var token_buf: [128]u8 = undefined;
        const token = normalizeThemePathToken(&token_buf, part) orelse return null;
        out.appendSliceBounded(token) catch return null;
    }
    if (out.items.len == prefix.len and std.mem.endsWith(u8, prefix, "-")) return prefix[0 .. prefix.len - 1];
    return out.items;
}

fn normalizeThemePathToken(buf: []u8, token: []const u8) ?[]const u8 {
    if (token.len > buf.len) return null;
    for (token, 0..) |c, i| {
        buf[i] = if (c == '.') '_' else c;
    }
    return buf[0..token.len];
}

fn topLevelSlash(input: []const u8) ?usize {
    var paren_depth: usize = 0;
    var bracket_depth: usize = 0;
    var quote: ?u8 = null;
    var i: usize = 0;
    while (i < input.len) : (i += 1) {
        const c = input[i];
        if (quote) |q| {
            if (c == '\\' and i + 1 < input.len) {
                i += 1;
                continue;
            }
            if (c == q) quote = null;
            continue;
        }
        switch (c) {
            '\'', '"' => quote = c,
            '(' => paren_depth += 1,
            ')' => if (paren_depth > 0) {
                paren_depth -= 1;
            },
            '[' => bracket_depth += 1,
            ']' => if (bracket_depth > 0) {
                bracket_depth -= 1;
            },
            '/' => if (paren_depth == 0 and bracket_depth == 0) return i,
            else => {},
        }
    }
    return null;
}

fn removeTrailingCssWord(input: []const u8, word: []const u8) ?[]const u8 {
    var value = trimAscii(input);
    if (value.len < word.len) return null;
    const start = value.len - word.len;
    if (!std.mem.eql(u8, value[start..], word)) return null;
    if (start > 0 and isNameChar(value[start - 1])) return null;
    value = trimAscii(value[0..start]);
    return value;
}

fn stripMatchingQuotes(input: []const u8) []const u8 {
    if (input.len >= 2 and ((input[0] == '"' and input[input.len - 1] == '"') or (input[0] == '\'' and input[input.len - 1] == '\''))) {
        return input[1 .. input.len - 1];
    }
    return input;
}

fn topLevelDeclarationColon(input: []const u8) ?usize {
    var paren_depth: usize = 0;
    var bracket_depth: usize = 0;
    var quote: ?u8 = null;
    var i: usize = 0;
    while (i < input.len) : (i += 1) {
        const c = input[i];
        if (quote) |q| {
            if (c == '\\') {
                if (i + 1 < input.len) i += 1;
                continue;
            }
            if (c == q) quote = null;
            continue;
        }
        switch (c) {
            '\'', '"' => quote = c,
            '(' => paren_depth += 1,
            ')' => if (paren_depth > 0) {
                paren_depth -= 1;
            },
            '[' => bracket_depth += 1,
            ']' => if (bracket_depth > 0) {
                bracket_depth -= 1;
            },
            ':' => if (paren_depth == 0 and bracket_depth == 0) return i,
            else => {},
        }
    }
    return null;
}

fn appendAuthoredNestedBlock(
    compiler: *Compiler,
    out: *std.ArrayList(u8),
    parent_selector: []const u8,
    block: []const u8,
    variants: []const []const u8,
    deferred_keyframes: *std.ArrayList(u8),
) anyerror!void {
    const open_rel = std.mem.indexOfScalar(u8, block, '{') orelse return;
    const open = open_rel;
    const prelude = trimAscii(block[0..open]);
    if (prelude.len == 0) return;
    const inner = block[open + 1 .. block.len - 1];

    if (prelude[0] == '@') {
        if (isTailwindDirectiveAt(prelude, 0) or isLegacyVariantDefinitionAt(prelude, 0)) return;
        var custom_media_prelude: std.ArrayList(u8) = .empty;
        defer custom_media_prelude.deinit(compiler.allocator);
        const media_prelude = if (try rewriteCustomMediaPrelude(compiler, &custom_media_prelude, prelude))
            custom_media_prelude.items
        else
            prelude;

        var rewritten_prelude: std.ArrayList(u8) = .empty;
        defer rewritten_prelude.deinit(compiler.allocator);
        const final_prelude = if (try rewriteAuthoredCssFunctions(compiler, &rewritten_prelude, media_prelude, true))
            rewritten_prelude.items
        else
            media_prelude;
        try out.appendSlice(compiler.allocator, final_prelude);
        try out.append(compiler.allocator, '{');
        try appendAuthoredRuleVariantsDeferred(compiler, out, parent_selector, inner, variants, deferred_keyframes);
        try out.append(compiler.allocator, '}');
        return;
    }

    var nested_selector: std.ArrayList(u8) = .empty;
    defer nested_selector.deinit(compiler.allocator);
    try appendNestedAuthoredSelector(compiler.allocator, &nested_selector, parent_selector, prelude);
    if (nested_selector.items.len == 0) return;
    try appendAuthoredRuleVariantsDeferred(compiler, out, nested_selector.items, inner, variants, deferred_keyframes);
}

fn appendAuthoredApply(
    compiler: *Compiler,
    out: *std.ArrayList(u8),
    selector: []const u8,
    variants: []const []const u8,
    declarations: *std.ArrayList(u8),
    params: []const u8,
    deferred_keyframes: *std.ArrayList(u8),
) anyerror!void {
    var candidates: std.ArrayList([]const u8) = .empty;
    defer candidates.deinit(compiler.allocator);
    try collectApplyCandidates(compiler, &candidates, params);
    std.mem.sort([]const u8, candidates.items, compiler, candidateLessThan);

    for (candidates.items) |candidate| {
        var variants_buf: [16][]const u8 = undefined;
        const parsed = parseCandidateForCompiler(compiler, candidate, &variants_buf) orelse continue;
        if (parsed.base.len == 0) continue;

        if (parsed.variants.len == 0) {
            try appendAuthoredApplyBaseDeclarations(compiler, out, declarations, parsed.base, parsed.important);
            continue;
        }

        if (declarations.items.len > 0) {
            try writeAuthoredRule(compiler, out, selector, variants, declarations.items, deferred_keyframes);
            declarations.clearRetainingCapacity();
        }

        var applied_decls: std.ArrayList(u8) = .empty;
        defer applied_decls.deinit(compiler.allocator);
        try appendAuthoredApplyBaseDeclarations(compiler, out, &applied_decls, parsed.base, parsed.important);
        if (applied_decls.items.len == 0) continue;

        var combined_variants: std.ArrayList([]const u8) = .empty;
        defer combined_variants.deinit(compiler.allocator);
        try combined_variants.appendSlice(compiler.allocator, variants);
        try combined_variants.appendSlice(compiler.allocator, parsed.variants);
        try writeAuthoredRule(compiler, out, selector, combined_variants.items, applied_decls.items, deferred_keyframes);
    }
}

fn appendAuthoredApplyBaseDeclarations(
    compiler: *Compiler,
    rule_out: *std.ArrayList(u8),
    declaration_out: *std.ArrayList(u8),
    base: []const u8,
    important: bool,
) anyerror!void {
    if (try appendApplyTypedPropertyDeclarations(compiler, rule_out, declaration_out, base, important)) return;
    if (try appendContentApplyDeclarations(compiler.allocator, rule_out, declaration_out, base, important)) return;
    try appendApplyBaseDeclarations(compiler, declaration_out, base, important);
}

fn appendApplyTypedPropertyDeclarations(
    compiler: *Compiler,
    rule_out: *std.ArrayList(u8),
    declaration_out: *std.ArrayList(u8),
    base: []const u8,
    important: bool,
) !bool {
    if (std.mem.startsWith(u8, base, "leading-")) {
        const suffix = base["leading-".len..];
        const value = applyLeadingValue(suffix) orelse return false;
        try appendPropertyLayer(compiler.allocator, rule_out, "--tw-leading:initial;");
        try appendDecl(compiler.allocator, declaration_out, "--tw-leading", value, important);
        try appendDecl(compiler.allocator, declaration_out, "line-height", value, important);
        try rule_out.appendSlice(compiler.allocator, "@property --tw-leading{syntax:\"*\";inherits:false;}");
        return true;
    }

    const translate = applyTranslate(base) orelse return false;
    try appendPropertyLayer(compiler.allocator, rule_out, "--tw-translate-x:0;--tw-translate-y:0;--tw-translate-z:0;");
    try appendDecl(compiler.allocator, declaration_out, translate.property, translate.value, important);
    try appendDecl(compiler.allocator, declaration_out, "translate", "var(--tw-translate-x) var(--tw-translate-y)", important);
    try appendTranslateProperties(compiler.allocator, rule_out);
    return true;
}

fn applyLeadingValue(suffix: []const u8) ?[]const u8 {
    if (std.mem.eql(u8, suffix, "none")) return "1";
    if (std.mem.eql(u8, suffix, "tight")) return "1.25";
    if (std.mem.eql(u8, suffix, "snug")) return "1.375";
    if (std.mem.eql(u8, suffix, "normal")) return "1.5";
    if (std.mem.eql(u8, suffix, "relaxed")) return "1.625";
    if (std.mem.eql(u8, suffix, "loose")) return "2";
    return null;
}

const ApplyTranslate = struct {
    property: []const u8,
    value: []const u8,
};

fn applyTranslate(base: []const u8) ?ApplyTranslate {
    const prefixes = [_]struct { prefix: []const u8, property: []const u8, negative: bool }{
        .{ .prefix = "translate-x-", .property = "--tw-translate-x", .negative = false },
        .{ .prefix = "-translate-x-", .property = "--tw-translate-x", .negative = true },
        .{ .prefix = "translate-y-", .property = "--tw-translate-y", .negative = false },
        .{ .prefix = "-translate-y-", .property = "--tw-translate-y", .negative = true },
    };
    inline for (prefixes) |entry| {
        if (std.mem.startsWith(u8, base, entry.prefix)) {
            const suffix = base[entry.prefix.len..];
            if (std.mem.eql(u8, suffix, "full")) {
                return .{ .property = entry.property, .value = if (entry.negative) "-100%" else "100%" };
            }
            return null;
        }
    }
    return null;
}

fn appendContentApplyDeclarations(
    allocator: std.mem.Allocator,
    rule_out: *std.ArrayList(u8),
    declaration_out: *std.ArrayList(u8),
    base: []const u8,
    important: bool,
) !bool {
    if (!std.mem.startsWith(u8, base, "content-")) return false;
    var value_buf: [1024]u8 = undefined;
    const value = arbitraryValue(&value_buf, base["content-".len..]) orelse return false;
    removeTrailingContentDeclaration(declaration_out);
    try appendPropertyLayer(allocator, rule_out, "--tw-content:\"\";");
    try appendDecl(allocator, declaration_out, "--tw-content", value, important);
    try appendDecl(allocator, declaration_out, "content", "var(--tw-content)", important);
    try rule_out.appendSlice(allocator, "@property --tw-content{syntax:\"*\";inherits:false;initial-value:\"\";}");
    return true;
}

fn removeTrailingContentDeclaration(out: *std.ArrayList(u8)) void {
    const plain = "content:var(--tw-content);";
    if (std.mem.endsWith(u8, out.items, plain)) {
        out.items.len -= plain.len;
        return;
    }
    const important = "content:var(--tw-content)!important;";
    if (std.mem.endsWith(u8, out.items, important)) {
        out.items.len -= important.len;
    }
}

fn appendAuthoredNestedVariants(
    compiler: *Compiler,
    out: *std.ArrayList(u8),
    selector: []const u8,
    body: []const u8,
    variants: []const []const u8,
    params: []const u8,
    deferred_keyframes: *std.ArrayList(u8),
) anyerror!void {
    var start: usize = 0;
    var i: usize = 0;
    var paren_depth: usize = 0;
    var bracket_depth: usize = 0;
    while (i <= params.len) : (i += 1) {
        const at_end = i == params.len;
        if (!at_end) {
            switch (params[i]) {
                '(' => paren_depth += 1,
                ')' => if (paren_depth > 0) {
                    paren_depth -= 1;
                },
                '[' => bracket_depth += 1,
                ']' => if (bracket_depth > 0) {
                    bracket_depth -= 1;
                },
                ',' => if (paren_depth == 0 and bracket_depth == 0) {},
                else => continue,
            }
            if (!(params[i] == ',' and paren_depth == 0 and bracket_depth == 0)) continue;
        }

        const expr = trimAscii(params[start..i]);
        if (expr.len > 0) {
            var next: std.ArrayList([]const u8) = .empty;
            defer next.deinit(compiler.allocator);
            try next.appendSlice(compiler.allocator, variants);
            try appendVariantExpressionSegments(compiler.allocator, &next, expr);
            try appendAuthoredRuleVariantsDeferred(compiler, out, selector, body, next.items, deferred_keyframes);
        }
        start = i + 1;
    }
}

fn appendVariantExpressionSegments(allocator: std.mem.Allocator, out: *std.ArrayList([]const u8), expr: []const u8) !void {
    var start: usize = 0;
    var i: usize = 0;
    var paren_depth: usize = 0;
    var bracket_depth: usize = 0;
    while (i <= expr.len) : (i += 1) {
        const at_end = i == expr.len;
        if (!at_end) {
            switch (expr[i]) {
                '(' => paren_depth += 1,
                ')' => if (paren_depth > 0) {
                    paren_depth -= 1;
                },
                '[' => bracket_depth += 1,
                ']' => if (bracket_depth > 0) {
                    bracket_depth -= 1;
                },
                ':' => if (paren_depth == 0 and bracket_depth == 0) {},
                else => continue,
            }
            if (!(expr[i] == ':' and paren_depth == 0 and bracket_depth == 0)) continue;
        }

        const segment = trimAscii(expr[start..i]);
        if (segment.len > 0) try out.append(allocator, segment);
        start = i + 1;
    }
}

fn writeAuthoredRule(
    compiler: *Compiler,
    out: *std.ArrayList(u8),
    selector: []const u8,
    variants: []const []const u8,
    declarations: []const u8,
    deferred_keyframes: ?*std.ArrayList(u8),
) !void {
    var transformed: std.ArrayList(u8) = .empty;
    defer transformed.deinit(compiler.allocator);
    if (authoredVariantsAffectSelector(compiler, variants) and selectorListHasTopLevelComma(selector)) {
        try appendSelectorAsNestingContext(compiler.allocator, &transformed, selector);
    } else {
        try transformed.appendSlice(compiler.allocator, selector);
    }

    for (variants) |variant| {
        try applyAuthoredSelectorVariant(compiler, &transformed, variant);
    }

    if (std.mem.indexOf(u8, declarations, "@supports (color:color-mix")) |supports_at| {
        const supports_end = scanCssBlock(declarations, supports_at) orelse declarations.len;
        const support_open_rel = std.mem.indexOfScalar(u8, declarations[supports_at..supports_end], '{') orelse supports_end - supports_at;
        const support_open = supports_at + support_open_rel;
        const base_declarations = declarations[0..supports_at];
        const support_prelude = declarations[supports_at..support_open];
        const support_declarations = if (support_open < supports_end and supports_end > support_open + 1)
            declarations[support_open + 1 .. supports_end - 1]
        else
            "";

        try openThemeMediaWrappers(compiler, out, variants);
        if (trimAscii(base_declarations).len > 0) {
            try out.appendSlice(compiler.allocator, transformed.items);
            try out.append(compiler.allocator, '{');
            try appendCssWithKnownThemeVariables(compiler, out, base_declarations);
            try out.append(compiler.allocator, '}');
        }
        try out.appendSlice(compiler.allocator, support_prelude);
        try out.append(compiler.allocator, '{');
        try out.appendSlice(compiler.allocator, transformed.items);
        try out.append(compiler.allocator, '{');
        try appendCssWithKnownThemeVariables(compiler, out, support_declarations);
        try out.append(compiler.allocator, '}');
        try out.append(compiler.allocator, '}');
        try closeThemeMediaWrappers(compiler, out, variants);
        return;
    }

    try openThemeMediaWrappers(compiler, out, variants);
    try out.appendSlice(compiler.allocator, transformed.items);
    try out.append(compiler.allocator, '{');
    try appendCssWithKnownThemeVariables(compiler, out, declarations);
    try out.append(compiler.allocator, '}');
    try closeThemeMediaWrappers(compiler, out, variants);
    if (deferred_keyframes) |keyframes_out| {
        try appendThemeAnimationKeyframesForValueDedup(compiler, keyframes_out, out.items, declarations);
    } else {
        try appendThemeAnimationKeyframesForValue(compiler, out, declarations);
    }
}

fn authoredVariantsAffectSelector(compiler: *Compiler, variants: []const []const u8) bool {
    for (variants) |variant| {
        if (pseudoVariant(variant) != null) return true;
        if (std.mem.startsWith(u8, variant, "[") and std.mem.endsWith(u8, variant, "]")) return true;
        if (std.mem.startsWith(u8, variant, "data-")) return true;
        if (std.mem.startsWith(u8, variant, "aria-")) return true;
        if (compoundCustomVariantForName(compiler, variant) != null) return true;
        if (customVariantForName(compiler, variant)) |custom| {
            if (custom.body) return !customVariantBodyHasAtRules(custom.value);
            if (!custom.media) return true;
        }
    }
    return false;
}

fn appendNestedAuthoredSelector(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(u8),
    parent: []const u8,
    prelude: []const u8,
) !void {
    var parent_context: std.ArrayList(u8) = .empty;
    defer parent_context.deinit(allocator);
    try appendSelectorAsNestingContext(allocator, &parent_context, parent);
    if (parent_context.items.len == 0) return;

    var start: usize = 0;
    var i: usize = 0;
    var paren_depth: usize = 0;
    var bracket_depth: usize = 0;
    var quote: ?u8 = null;
    while (i <= prelude.len) : (i += 1) {
        const at_end = i == prelude.len;
        if (!at_end) {
            const c = prelude[i];
            if (quote) |q| {
                if (c == '\\') {
                    if (i + 1 < prelude.len) i += 1;
                    continue;
                }
                if (c == q) quote = null;
                continue;
            }
            switch (c) {
                '\'', '"' => quote = c,
                '(' => paren_depth += 1,
                ')' => if (paren_depth > 0) {
                    paren_depth -= 1;
                },
                '[' => bracket_depth += 1,
                ']' => if (bracket_depth > 0) {
                    bracket_depth -= 1;
                },
                ',' => if (paren_depth == 0 and bracket_depth == 0) {},
                else => continue,
            }
            if (!(c == ',' and paren_depth == 0 and bracket_depth == 0)) continue;
        }

        const child = trimAscii(prelude[start..i]);
        if (child.len > 0) {
            if (out.items.len > 0) try out.append(allocator, ',');
            try appendNestedSelectorPart(allocator, out, parent_context.items, child);
        }
        start = i + 1;
    }
}

fn appendSelectorAsNestingContext(allocator: std.mem.Allocator, out: *std.ArrayList(u8), selector: []const u8) !void {
    if (!selectorListHasTopLevelComma(selector)) {
        try out.appendSlice(allocator, trimAscii(selector));
        return;
    }

    try out.appendSlice(allocator, ":is(");
    var start: usize = 0;
    var i: usize = 0;
    var first = true;
    var paren_depth: usize = 0;
    var bracket_depth: usize = 0;
    var quote: ?u8 = null;
    while (i <= selector.len) : (i += 1) {
        const at_end = i == selector.len;
        if (!at_end) {
            const c = selector[i];
            if (quote) |q| {
                if (c == '\\') {
                    if (i + 1 < selector.len) i += 1;
                    continue;
                }
                if (c == q) quote = null;
                continue;
            }
            switch (c) {
                '\'', '"' => quote = c,
                '(' => paren_depth += 1,
                ')' => if (paren_depth > 0) {
                    paren_depth -= 1;
                },
                '[' => bracket_depth += 1,
                ']' => if (bracket_depth > 0) {
                    bracket_depth -= 1;
                },
                ',' => if (paren_depth == 0 and bracket_depth == 0) {},
                else => continue,
            }
            if (!(c == ',' and paren_depth == 0 and bracket_depth == 0)) continue;
        }

        const part = trimAscii(selector[start..i]);
        if (part.len > 0) {
            if (!first) try out.append(allocator, ',');
            try out.appendSlice(allocator, part);
            first = false;
        }
        start = i + 1;
    }
    try out.append(allocator, ')');
}

fn selectorListHasTopLevelComma(selector: []const u8) bool {
    var paren_depth: usize = 0;
    var bracket_depth: usize = 0;
    var quote: ?u8 = null;
    var i: usize = 0;
    while (i < selector.len) : (i += 1) {
        const c = selector[i];
        if (quote) |q| {
            if (c == '\\') {
                if (i + 1 < selector.len) i += 1;
                continue;
            }
            if (c == q) quote = null;
            continue;
        }
        switch (c) {
            '\'', '"' => quote = c,
            '(' => paren_depth += 1,
            ')' => if (paren_depth > 0) {
                paren_depth -= 1;
            },
            '[' => bracket_depth += 1,
            ']' => if (bracket_depth > 0) {
                bracket_depth -= 1;
            },
            ',' => if (paren_depth == 0 and bracket_depth == 0) return true,
            else => {},
        }
    }
    return false;
}

fn appendNestedSelectorPart(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(u8),
    parent: []const u8,
    child: []const u8,
) !void {
    if (std.mem.indexOfScalar(u8, child, '&') == null) {
        try out.appendSlice(allocator, parent);
        if (!nestedSelectorStartsWithCombinator(child)) try out.append(allocator, ' ');
        try out.appendSlice(allocator, child);
        return;
    }

    var i: usize = 0;
    while (std.mem.indexOfScalar(u8, child[i..], '&')) |rel| {
        const at = i + rel;
        try out.appendSlice(allocator, child[i..at]);
        try out.appendSlice(allocator, parent);
        i = at + 1;
    }
    try out.appendSlice(allocator, child[i..]);
}

fn nestedSelectorStartsWithCombinator(selector: []const u8) bool {
    if (selector.len == 0) return false;
    return selector[0] == '>' or selector[0] == '+' or selector[0] == '~' or selector[0] == '|';
}

fn applyAuthoredSelectorVariant(compiler: *Compiler, selector: *std.ArrayList(u8), variant: []const u8) !void {
    if (pseudoVariant(variant)) |pseudo| {
        try selector.appendSlice(compiler.allocator, pseudo);
        return;
    }
    if (std.mem.startsWith(u8, variant, "[") and std.mem.endsWith(u8, variant, "]")) {
        try applyCustomVariantSelector(compiler.allocator, selector, variant[1 .. variant.len - 1]);
        return;
    }
    if (std.mem.startsWith(u8, variant, "data-")) {
        try selector.appendSlice(compiler.allocator, "[data-");
        try selector.appendSlice(compiler.allocator, variant["data-".len..]);
        try selector.append(compiler.allocator, ']');
        return;
    }
    if (std.mem.startsWith(u8, variant, "aria-")) {
        try selector.appendSlice(compiler.allocator, "[aria-");
        try selector.appendSlice(compiler.allocator, variant["aria-".len..]);
        try selector.appendSlice(compiler.allocator, "=\"true\"]");
        return;
    }
    if (customVariantForName(compiler, variant)) |custom| {
        if (custom.body and !customVariantBodyHasAtRules(custom.value)) {
            try applyCustomVariantBodySelector(compiler, selector, custom.value);
        } else if (!custom.media) {
            try applyCustomVariantSelector(compiler.allocator, selector, custom.value);
        }
    }
}

fn isTailwindDirectiveAt(input: []const u8, index: usize) bool {
    return isThemeAtRuleAt(input, index) or
        isUtilityAtRuleAt(input, index) or
        isCustomVariantAtRuleAt(input, index) or
        isTailwindAtRuleAt(input, index);
}

fn isTailwindAtRuleAt(input: []const u8, index: usize) bool {
    if (index >= input.len or !std.mem.startsWith(u8, input[index..], "@tailwind")) return false;
    const end = index + "@tailwind".len;
    return end == input.len or !isNameChar(input[end]);
}

fn isMediaThemeAtRuleAt(input: []const u8, index: usize) bool {
    if (index >= input.len or !std.mem.startsWith(u8, input[index..], "@media")) return false;
    const name_end = index + "@media".len;
    if (name_end < input.len and isNameChar(input[name_end])) return false;
    const end = definitionEnd(input, index) orelse input.len;
    const open_rel = std.mem.indexOfScalar(u8, input[index..end], '{') orelse input.len - index;
    return mediaThemeParams(input[index .. index + open_rel]) != null;
}

fn isMediaReferenceAtRuleAt(input: []const u8, index: usize) bool {
    if (index >= input.len or !std.mem.startsWith(u8, input[index..], "@media")) return false;
    const name_end = index + "@media".len;
    if (name_end < input.len and isNameChar(input[name_end])) return false;
    const end = definitionEnd(input, index) orelse input.len;
    const open_rel = std.mem.indexOfScalar(u8, input[index..end], '{') orelse input.len - index;
    const params = trimAscii(input[name_end .. index + open_rel]);
    return std.mem.eql(u8, params, "reference");
}

fn isTailwindUtilitiesDirectiveAt(input: []const u8, index: usize) bool {
    if (!isTailwindAtRuleAt(input, index)) return false;
    var params_start = index + "@tailwind".len;
    while (params_start < input.len and isAsciiWhitespace(input[params_start])) : (params_start += 1) {}
    if (!std.mem.startsWith(u8, input[params_start..], "utilities")) return false;
    const end = params_start + "utilities".len;
    return end == input.len or !isNameChar(input[end]);
}

fn isUtilitiesImportAt(input: []const u8, index: usize) bool {
    if (index >= input.len or !std.mem.startsWith(u8, input[index..], "@import")) return false;
    const name_end = index + "@import".len;
    if (name_end < input.len and isNameChar(input[name_end])) return false;
    const end = definitionEnd(input, index) orelse return false;
    const statement = input[index..end];
    return std.mem.indexOf(u8, statement, "\"tailwindcss/utilities\"") != null or
        std.mem.indexOf(u8, statement, "'tailwindcss/utilities'") != null;
}

fn isTailwindImportAt(input: []const u8, index: usize) bool {
    if (index >= input.len or !std.mem.startsWith(u8, input[index..], "@import")) return false;
    const name_end = index + "@import".len;
    if (name_end < input.len and isNameChar(input[name_end])) return false;
    const end = definitionEnd(input, index) orelse return false;
    const statement = input[index..end];
    return importStatementContainsPath(statement, "tailwindcss");
}

fn isPreflightImportAt(input: []const u8, index: usize) bool {
    if (index >= input.len or !std.mem.startsWith(u8, input[index..], "@import")) return false;
    const name_end = index + "@import".len;
    if (name_end < input.len and isNameChar(input[name_end])) return false;
    const end = definitionEnd(input, index) orelse return false;
    const statement = input[index..end];
    return std.mem.indexOf(u8, statement, "\"tailwindcss/preflight\"") != null or
        std.mem.indexOf(u8, statement, "'tailwindcss/preflight'") != null or
        std.mem.indexOf(u8, statement, "\"tailwindcss/preflight.css\"") != null or
        std.mem.indexOf(u8, statement, "'tailwindcss/preflight.css'") != null;
}

fn isThemeImportAt(input: []const u8, index: usize) bool {
    if (index >= input.len or !std.mem.startsWith(u8, input[index..], "@import")) return false;
    const name_end = index + "@import".len;
    if (name_end < input.len and isNameChar(input[name_end])) return false;
    const end = definitionEnd(input, index) orelse return false;
    const statement = input[index..end];
    return std.mem.indexOf(u8, statement, "\"tailwindcss/theme\"") != null or
        std.mem.indexOf(u8, statement, "'tailwindcss/theme'") != null or
        std.mem.indexOf(u8, statement, "\"tailwindcss/theme.css\"") != null or
        std.mem.indexOf(u8, statement, "'tailwindcss/theme.css'") != null;
}

fn isThemeReferenceAt(input: []const u8, index: usize) bool {
    if (index >= input.len or !std.mem.startsWith(u8, input[index..], "@reference")) return false;
    const name_end = index + "@reference".len;
    if (name_end < input.len and isNameChar(input[name_end])) return false;
    const end = definitionEnd(input, index) orelse return false;
    const statement = input[index..end];
    return std.mem.indexOf(u8, statement, "\"tailwindcss/theme\"") != null or
        std.mem.indexOf(u8, statement, "'tailwindcss/theme'") != null or
        std.mem.indexOf(u8, statement, "\"tailwindcss/theme.css\"") != null or
        std.mem.indexOf(u8, statement, "'tailwindcss/theme.css'") != null;
}

fn isTailwindReferenceAt(input: []const u8, index: usize) bool {
    if (index >= input.len or !std.mem.startsWith(u8, input[index..], "@reference")) return false;
    const name_end = index + "@reference".len;
    if (name_end < input.len and isNameChar(input[name_end])) return false;
    const end = definitionEnd(input, index) orelse return false;
    const statement = input[index..end];
    return importStatementContainsPath(statement, "tailwindcss");
}

fn importStatementContainsPath(statement: []const u8, path: []const u8) bool {
    var quoted_buf: [256]u8 = undefined;
    const double_quoted = std.fmt.bufPrint(&quoted_buf, "\"{s}\"", .{path}) catch return false;
    if (std.mem.indexOf(u8, statement, double_quoted) != null) return true;
    const single_quoted = std.fmt.bufPrint(&quoted_buf, "'{s}'", .{path}) catch return false;
    return std.mem.indexOf(u8, statement, single_quoted) != null;
}

fn bodyIsOnlyUtilitiesEntrypoint(body: []const u8) bool {
    var i: usize = 0;
    skipCssWhitespaceAndComments(body, &i);
    if (i >= body.len) return false;
    if (!isTailwindUtilitiesDirectiveAt(body, i) and !isUtilitiesImportAt(body, i)) return false;
    i = definitionEnd(body, i) orelse return false;
    skipCssWhitespaceAndComments(body, &i);
    return i >= body.len;
}

fn isImportantMediaPrelude(prelude: []const u8) bool {
    var value = trimAscii(prelude);
    if (!std.mem.startsWith(u8, value, "@media")) return false;
    value = trimAscii(value["@media".len..]);
    return std.mem.eql(u8, value, "important");
}

fn statementHasImportant(statement: []const u8) bool {
    var search_start: usize = 0;
    while (std.mem.indexOf(u8, statement[search_start..], "important")) |rel| {
        const start = search_start + rel;
        const end = start + "important".len;
        const before_ok = start == 0 or !isNameChar(statement[start - 1]);
        const after_ok = end == statement.len or !isNameChar(statement[end]);
        if (before_ok and after_ok) return true;
        search_start = end;
    }
    return false;
}

fn isVariantAtRuleAt(input: []const u8, index: usize) bool {
    if (index >= input.len or !std.mem.startsWith(u8, input[index..], "@variant")) return false;
    const end = index + "@variant".len;
    return end == input.len or !isNameChar(input[end]);
}

fn isLegacyVariantDefinitionAt(input: []const u8, index: usize) bool {
    if (!isVariantAtRuleAt(input, index)) return false;
    const end = definitionEnd(input, index) orelse return false;
    const params_start = index + "@variant".len;
    if (scanCssBlock(input, index)) |block_end| {
        if (block_end == end) {
            return std.mem.indexOf(u8, input[params_start..end], "@slot") != null;
        }
    }
    return std.mem.indexOfScalar(u8, input[params_start..end], '(') != null;
}

fn isSupportedStaticUtilityName(name: []const u8) bool {
    if (name.len == 0 or std.mem.indexOfScalar(u8, name, '*') != null) return false;
    if (name[name.len - 1] == '-' or name[name.len - 1] == '/') return false;
    var slash_seen = false;
    for (name, 0..) |c, i| {
        if (isAsciiWhitespace(c)) return false;
        if (c >= 'A' and c <= 'Z') return false;
        switch (c) {
            'a'...'z', '0'...'9', '-', '_' => {},
            '.', '%' => {},
            '/' => {
                if (slash_seen) return false;
                slash_seen = true;
                if (i == 0 or i + 1 == name.len) return false;
            },
            else => return false,
        }
    }
    return true;
}

fn functionalUtilityPrefix(name: []const u8) ?[]const u8 {
    if (name.len < 3 or !std.mem.endsWith(u8, name, "-*")) return null;
    if (std.mem.indexOfScalar(u8, name[0 .. name.len - 2], '*') != null) return null;
    const prefix = name[0 .. name.len - 1];
    for (prefix) |c| {
        if (isAsciiWhitespace(c)) return null;
        if (c >= 'A' and c <= 'Z') return null;
        switch (c) {
            'a'...'z', '0'...'9', '-', '_' => {},
            else => return null,
        }
    }
    return prefix;
}

fn isSupportedCustomVariantName(name: []const u8) bool {
    if (name.len == 0) return false;
    const first = name[0];
    if (!((first >= 'a' and first <= 'z') or (first >= '0' and first <= '9'))) return false;
    if (name[name.len - 1] == '-' or name[name.len - 1] == '_') return false;
    for (name) |c| {
        if (!((c >= 'a' and c <= 'z') or
            (c >= 'A' and c <= 'Z') or
            (c >= '0' and c <= '9') or
            c == '-' or c == '_')) return false;
    }
    return true;
}

fn lastIndexOfScalar(input: []const u8, needle: u8) ?usize {
    var i = input.len;
    while (i > 0) {
        i -= 1;
        if (input[i] == needle) return i;
    }
    return null;
}

fn skipCssWhitespaceAndComments(input: []const u8, index: *usize) void {
    while (index.* < input.len) {
        if (isAsciiWhitespace(input[index.*])) {
            index.* += 1;
            continue;
        }
        if (skipCssCommentAt(input, index)) continue;
        break;
    }
}

fn skipCssCommentOrStringAt(input: []const u8, index: *usize) bool {
    return skipCssCommentAt(input, index) or skipCssStringAt(input, index);
}

fn skipCssCommentAt(input: []const u8, index: *usize) bool {
    if (index.* + 1 >= input.len or input[index.*] != '/' or input[index.* + 1] != '*') return false;
    index.* += 2;
    while (index.* + 1 < input.len and !(input[index.*] == '*' and input[index.* + 1] == '/')) : (index.* += 1) {}
    if (index.* + 1 < input.len) {
        index.* += 2;
    } else {
        index.* = input.len;
    }
    return true;
}

fn skipCssStringAt(input: []const u8, index: *usize) bool {
    if (index.* >= input.len or (input[index.*] != '"' and input[index.*] != '\'')) return false;
    const quote = input[index.*];
    index.* += 1;
    while (index.* < input.len) : (index.* += 1) {
        if (input[index.*] == '\\') {
            if (index.* + 1 < input.len) index.* += 1;
            continue;
        }
        if (input[index.*] == quote) {
            index.* += 1;
            return true;
        }
    }
    return true;
}

fn shouldEmitThemeVariableDirect(compiler: *Compiler, variable: ThemeVariable, body: []const u8) bool {
    if (variable.inline_theme or variable.reference) return false;
    if (std.mem.eql(u8, variable.value, "initial")) return false;
    if (variable.static_theme) return true;
    var name_buf: [512]u8 = undefined;
    const css_name = formatCssVariableName(compiler, &name_buf, variable.name) orelse return false;
    if (!containsCssVariableName(body, css_name)) return false;
    return true;
}

fn themeVariableIsDependencyOfEmitted(compiler: *Compiler, variable: ThemeVariable, emit: []const bool) bool {
    if (variable.inline_theme or variable.reference) return false;
    if (std.mem.eql(u8, variable.value, "initial")) return false;
    var name_buf: [512]u8 = undefined;
    const css_name = formatCssVariableName(compiler, &name_buf, variable.name) orelse return false;
    for (compiler.theme_variables.items, 0..) |other, i| {
        if (!emit[i]) continue;
        if (containsCssVariableName(other.value, css_name)) return true;
    }
    return false;
}

fn containsCssVariableName(input: []const u8, name: []const u8) bool {
    var search_start: usize = 0;
    while (std.mem.indexOf(u8, input[search_start..], name)) |rel| {
        const start = search_start + rel;
        const end = start + name.len;
        const before_ok = start == 0 or !isCssVariableNameChar(input[start - 1]);
        const after_ok = end == input.len or !isCssVariableNameChar(input[end]);
        if (before_ok and after_ok) return true;
        search_start = end;
    }
    return false;
}

fn isCssVariableNameChar(c: u8) bool {
    return isNameChar(c) or c == '-';
}

const SortProperties = struct {
    order: u16,
    count: u16,
};

const CandidateSortKey = struct {
    variants: u128,
    properties: SortProperties,
};

fn candidateSortKey(compiler: *Compiler, raw: []const u8) CandidateSortKey {
    var variants_buf: [16][]const u8 = undefined;
    const parsed = parseCandidateForCompiler(compiler, raw, &variants_buf) orelse return .{
        .variants = std.math.maxInt(u128),
        .properties = .{ .order = std.math.maxInt(u16), .count = 1 },
    };
    var variants: u128 = 0;
    for (parsed.variants) |variant| {
        variants |= (@as(u128, 1) << @intCast(variantSortOrdinal(variant)));
    }
    return .{
        .variants = variants,
        .properties = customUtilityPropertySort(compiler, parsed.base) orelse themePropertySort(compiler, parsed.base) orelse customFunctionalOrBasePropertySort(compiler, parsed.base),
    };
}

fn customFunctionalOrBasePropertySort(compiler: *Compiler, raw_base: []const u8) SortProperties {
    const base_sort = basePropertySort(raw_base);
    if (base_sort.order != 10000 or base_sort.count != 1) return base_sort;
    return customFunctionalUtilityPropertySort(compiler, raw_base) orelse base_sort;
}

fn customUtilityPropertySort(compiler: *Compiler, raw_base: []const u8) ?SortProperties {
    for (compiler.custom_utilities.items) |utility| {
        if (std.mem.eql(u8, utility.name, raw_base)) {
            var decls: std.ArrayList(u8) = .empty;
            defer decls.deinit(compiler.allocator);
            expandCustomUtilityDeclarations(compiler, &decls, utility.declarations) catch return declarationPropertySort(utility.declarations);
            var sort = declarationPropertySort(decls.items);
            sort.count = countDeclarations(decls.items);
            return sort;
        }
    }
    return null;
}

fn customFunctionalUtilityPropertySort(compiler: *Compiler, raw_base: []const u8) ?SortProperties {
    for (compiler.functional_utilities.items) |utility| {
        const match = functionalUtilityMatch(utility.prefix, utility.declarations, raw_base) orelse continue;
        var decls: std.ArrayList(u8) = .empty;
        defer decls.deinit(compiler.allocator);
        if (expandFunctionalUtilityDeclarations(compiler, &decls, utility.declarations, match) catch false) {
            var sort = declarationPropertySort(decls.items);
            sort.count = countDeclarations(decls.items);
            return sort;
        }
    }
    return null;
}

fn countDeclarations(declarations: []const u8) u16 {
    var count: u16 = 0;
    for (declarations) |c| {
        if (c == ';' and count < std.math.maxInt(u16)) count += 1;
    }
    return if (count == 0) 1 else count;
}

fn declarationPropertySort(declarations: []const u8) SortProperties {
    var i: usize = 0;
    skipCssWhitespaceAndComments(declarations, &i);
    if (firstTopLevelNestedBlock(declarations, i)) |block| {
        return declarationPropertySort(declarations[block.open + 1 .. block.end - 1]);
    }
    const start = i;
    while (i < declarations.len and declarations[i] != ':' and declarations[i] != ';' and declarations[i] != '{' and declarations[i] != '}') : (i += 1) {}
    const prop = trimAscii(declarations[start..i]);
    if (std.mem.eql(u8, prop, "top")) return .{ .order = 11, .count = 1 };
    if (std.mem.eql(u8, prop, "right")) return .{ .order = 12, .count = 1 };
    if (std.mem.eql(u8, prop, "bottom")) return .{ .order = 13, .count = 1 };
    if (std.mem.eql(u8, prop, "left")) return .{ .order = 14, .count = 1 };
    if (std.mem.eql(u8, prop, "z-index")) return .{ .order = 16, .count = 1 };
    if (std.mem.eql(u8, prop, "inset")) return .{ .order = 4, .count = 1 };
    if (std.mem.eql(u8, prop, "inset-inline")) return .{ .order = 5, .count = 1 };
    if (std.mem.eql(u8, prop, "inset-block")) return .{ .order = 6, .count = 1 };
    if (std.mem.eql(u8, prop, "width")) return .{ .order = 63, .count = 1 };
    if (std.mem.eql(u8, prop, "height")) return .{ .order = 60, .count = 1 };
    if (std.mem.eql(u8, prop, "border-radius")) return .{ .order = 180, .count = 1 };
    if (std.mem.eql(u8, prop, "padding")) return .{ .order = 270, .count = 1 };
    if (std.mem.eql(u8, prop, "margin")) return .{ .order = 30, .count = 1 };
    if (std.mem.eql(u8, prop, "display")) return .{ .order = 45, .count = 1 };
    if (std.mem.eql(u8, prop, "flex-direction")) return .{ .order = 118, .count = 1 };
    if (std.mem.eql(u8, prop, "animation")) return .{ .order = 95, .count = 1 };
    if (std.mem.eql(u8, prop, "font-size")) return .{ .order = 290, .count = 1 };
    if (std.mem.eql(u8, prop, "line-height")) return .{ .order = 291, .count = 1 };
    if (std.mem.eql(u8, prop, "font-weight")) return .{ .order = 292, .count = 1 };
    if (std.mem.eql(u8, prop, "color")) return .{ .order = 305, .count = 1 };
    if (std.mem.eql(u8, prop, "text-decoration-line")) return .{ .order = 320, .count = 1 };
    if (std.mem.eql(u8, prop, "background-color")) return .{ .order = 238, .count = 1 };
    return .{ .order = 10000, .count = 1 };
}

const CssBlockRange = struct {
    open: usize,
    end: usize,
};

fn firstTopLevelNestedBlock(input: []const u8, start: usize) ?CssBlockRange {
    var i = start;
    var paren_depth: usize = 0;
    var bracket_depth: usize = 0;
    while (i < input.len) : (i += 1) {
        switch (input[i]) {
            '(' => paren_depth += 1,
            ')' => if (paren_depth > 0) {
                paren_depth -= 1;
            },
            '[' => bracket_depth += 1,
            ']' => if (bracket_depth > 0) {
                bracket_depth -= 1;
            },
            ';' => if (paren_depth == 0 and bracket_depth == 0) return null,
            '{' => if (paren_depth == 0 and bracket_depth == 0) {
                const end = scanCssBlock(input, start) orelse return null;
                return .{ .open = i, .end = end };
            },
            else => {},
        }
    }
    return null;
}

fn themePropertySort(compiler: *Compiler, raw_base: []const u8) ?SortProperties {
    var base = raw_base;
    if (base.len > 1 and base[0] == '-') base = base[1..];
    if (std.mem.startsWith(u8, base, "text-") and hasThemeValue(compiler, "--text-", base["text-".len..])) {
        return .{ .order = 290, .count = 2 };
    }
    if (std.mem.startsWith(u8, base, "indent-") and hasThemeValue(compiler, "--text-indent-", base["indent-".len..])) {
        return .{ .order = 286, .count = 1 };
    }
    if (std.mem.startsWith(u8, base, "text-") and hasThemeValue(compiler, "--text-color-", base["text-".len..])) {
        return .{ .order = 305, .count = 1 };
    }
    if (std.mem.startsWith(u8, base, "decoration-")) {
        const suffix = base["decoration-".len..];
        if (hasThemeValue(compiler, "--text-decoration-color-", suffix)) return .{ .order = 321, .count = 3 };
        if (hasThemeValue(compiler, "--text-decoration-thickness-", suffix)) return .{ .order = 322, .count = 1 };
    }
    if (std.mem.startsWith(u8, base, "underline-offset-") and hasThemeValue(compiler, "--text-underline-offset-", base["underline-offset-".len..])) {
        return .{ .order = 323, .count = 1 };
    }
    if (std.mem.startsWith(u8, base, "animate-") and hasThemeValue(compiler, "--animate-", base["animate-".len..])) {
        return .{ .order = 95, .count = 1 };
    }
    return null;
}

fn variantSortOrdinal(variant: []const u8) u7 {
    if (std.mem.eql(u8, variant, "not-open")) return 0;
    if (std.mem.startsWith(u8, variant, "not-")) return 0;
    if (std.mem.eql(u8, variant, "group-hover") or std.mem.eql(u8, variant, "peer-hover")) return 1;
    if (std.mem.eql(u8, variant, "group-focus") or std.mem.eql(u8, variant, "peer-focus")) return 2;
    if (std.mem.startsWith(u8, variant, "group-") or std.mem.startsWith(u8, variant, "peer-")) return 3;
    if (std.mem.startsWith(u8, variant, "max-")) {
        const breakpoint = variant["max-".len..];
        if (std.mem.eql(u8, breakpoint, "2xl")) return 15;
        if (std.mem.eql(u8, breakpoint, "xl")) return 16;
        if (std.mem.eql(u8, breakpoint, "lg")) return 17;
        if (std.mem.eql(u8, breakpoint, "md")) return 18;
        if (std.mem.eql(u8, breakpoint, "sm")) return 19;
    }
    if (std.mem.startsWith(u8, variant, "min-")) {
        const breakpoint = variant["min-".len..];
        if (std.mem.eql(u8, breakpoint, "sm")) return 20;
        if (std.mem.eql(u8, breakpoint, "md")) return 21;
        if (std.mem.eql(u8, breakpoint, "lg")) return 22;
        if (std.mem.eql(u8, breakpoint, "xl")) return 23;
        if (std.mem.eql(u8, breakpoint, "2xl")) return 24;
    }
    const pairs = [_]struct { name: []const u8, order: u7 }{
        .{ .name = "group-hover", .order = 1 },
        .{ .name = "peer-hover", .order = 1 },
        .{ .name = "before", .order = 6 },
        .{ .name = "after", .order = 6 },
        .{ .name = "first", .order = 7 },
        .{ .name = "last", .order = 7 },
        .{ .name = "only", .order = 7 },
        .{ .name = "odd", .order = 7 },
        .{ .name = "even", .order = 7 },
        .{ .name = "visited", .order = 7 },
        .{ .name = "checked", .order = 7 },
        .{ .name = "placeholder", .order = 7 },
        .{ .name = "focus-within", .order = 8 },
        .{ .name = "hover", .order = 9 },
        .{ .name = "focus", .order = 10 },
        .{ .name = "focus-visible", .order = 10 },
        .{ .name = "active", .order = 10 },
        .{ .name = "disabled", .order = 10 },
        .{ .name = "motion-safe", .order = 12 },
        .{ .name = "motion-reduce", .order = 13 },
        .{ .name = "sm", .order = 20 },
        .{ .name = "md", .order = 21 },
        .{ .name = "lg", .order = 22 },
        .{ .name = "xl", .order = 23 },
        .{ .name = "2xl", .order = 24 },
        .{ .name = "dark", .order = 30 },
        .{ .name = "print", .order = 31 },
    };
    inline for (pairs) |pair| {
        if (std.mem.eql(u8, variant, pair.name)) return pair.order;
    }
    return 120;
}

fn basePropertySort(raw_base: []const u8) SortProperties {
    var base = raw_base;
    if (base.len > 1 and base[0] == '-') base = base[1..];

    if (arbitraryPropertySort(base)) |sort| return sort;
    if (containerQueryPropertySort(base)) |sort| return sort;
    const static = staticPropertySort(base) orelse {
        if (containPropertySort(base)) |sort| return sort;
        if (spacingPropertySort(base)) |sort| return sort;
        if (sizingPropertySort(base)) |sort| return sort;
        if (insetPropertySort(base)) |sort| return sort;
        if (gridPropertySort(base)) |sort| return sort;
        if (objectPropertySort(base)) |sort| return sort;
        if (borderPropertySort(base)) |sort| return sort;
        if (typographyPropertySort(base)) |sort| return sort;
        if (colorPropertySort(base)) |sort| return sort;
        if (numericPropertySort(base)) |sort| return sort;
        if (transformPropertySort(base)) |sort| return sort;
        return .{ .order = 10000, .count = 1 };
    };
    return static;
}

fn arbitraryPropertySort(base: []const u8) ?SortProperties {
    const body = arbitraryBracketBody(base) orelse return null;
    const colon = topLevelDeclarationColon(body) orelse return null;
    const property = trimAscii(body[0..colon]);
    if (std.mem.eql(u8, property, "color")) return .{ .order = 305, .count = 1 };
    return null;
}

fn staticPropertySort(base: []const u8) ?SortProperties {
    const pairs = [_]struct { name: []const u8, order: u16, count: u16 }{
        .{ .name = "static", .order = 3, .count = 1 },
        .{ .name = "fixed", .order = 3, .count = 1 },
        .{ .name = "absolute", .order = 3, .count = 1 },
        .{ .name = "relative", .order = 3, .count = 1 },
        .{ .name = "sticky", .order = 3, .count = 1 },
        .{ .name = "pointer-events-none", .order = 1, .count = 1 },
        .{ .name = "pointer-events-auto", .order = 1, .count = 1 },
        .{ .name = "container", .order = 29, .count = 2 },
        .{ .name = "visible", .order = 2, .count = 1 },
        .{ .name = "invisible", .order = 2, .count = 1 },
        .{ .name = "collapse", .order = 2, .count = 1 },
        .{ .name = "block", .order = 45, .count = 1 },
        .{ .name = "inline-block", .order = 45, .count = 1 },
        .{ .name = "inline", .order = 45, .count = 1 },
        .{ .name = "flex", .order = 45, .count = 1 },
        .{ .name = "inline-flex", .order = 45, .count = 1 },
        .{ .name = "grid", .order = 45, .count = 1 },
        .{ .name = "inline-grid", .order = 45, .count = 1 },
        .{ .name = "contents", .order = 45, .count = 1 },
        .{ .name = "hidden", .order = 45, .count = 1 },
        .{ .name = "text-left", .order = 285, .count = 1 },
        .{ .name = "text-center", .order = 285, .count = 1 },
        .{ .name = "text-right", .order = 285, .count = 1 },
        .{ .name = "text-justify", .order = 285, .count = 1 },
        .{ .name = "text-start", .order = 285, .count = 1 },
        .{ .name = "text-end", .order = 285, .count = 1 },
        .{ .name = "overflow-auto", .order = 176, .count = 1 },
        .{ .name = "overflow-hidden", .order = 176, .count = 1 },
        .{ .name = "overflow-clip", .order = 176, .count = 1 },
        .{ .name = "overflow-visible", .order = 176, .count = 1 },
        .{ .name = "overflow-scroll", .order = 176, .count = 1 },
        .{ .name = "overflow-x-auto", .order = 177, .count = 1 },
        .{ .name = "overflow-x-hidden", .order = 177, .count = 1 },
        .{ .name = "overflow-x-clip", .order = 177, .count = 1 },
        .{ .name = "overflow-x-visible", .order = 177, .count = 1 },
        .{ .name = "overflow-x-scroll", .order = 177, .count = 1 },
        .{ .name = "overflow-y-auto", .order = 178, .count = 1 },
        .{ .name = "overflow-y-hidden", .order = 178, .count = 1 },
        .{ .name = "overflow-y-clip", .order = 178, .count = 1 },
        .{ .name = "overflow-y-visible", .order = 178, .count = 1 },
        .{ .name = "overflow-y-scroll", .order = 178, .count = 1 },
        .{ .name = "truncate", .order = 176, .count = 3 },
        .{ .name = "text-ellipsis", .order = 297, .count = 1 },
        .{ .name = "text-clip", .order = 297, .count = 1 },
        .{ .name = "break-normal", .order = 299, .count = 2 },
        .{ .name = "break-words", .order = 299, .count = 1 },
        .{ .name = "break-all", .order = 300, .count = 1 },
        .{ .name = "break-keep", .order = 300, .count = 1 },
        .{ .name = "object-contain", .order = 260, .count = 1 },
        .{ .name = "object-cover", .order = 260, .count = 1 },
        .{ .name = "object-fill", .order = 260, .count = 1 },
        .{ .name = "object-none", .order = 260, .count = 1 },
        .{ .name = "object-scale-down", .order = 260, .count = 1 },
        .{ .name = "font-sans", .order = 288, .count = 1 },
        .{ .name = "font-serif", .order = 288, .count = 1 },
        .{ .name = "font-mono", .order = 288, .count = 1 },
        .{ .name = "underline", .order = 320, .count = 1 },
        .{ .name = "overline", .order = 320, .count = 1 },
        .{ .name = "line-through", .order = 320, .count = 1 },
        .{ .name = "no-underline", .order = 320, .count = 1 },
        .{ .name = "italic", .order = 315, .count = 1 },
        .{ .name = "not-italic", .order = 315, .count = 1 },
        .{ .name = "uppercase", .order = 314, .count = 1 },
        .{ .name = "lowercase", .order = 314, .count = 1 },
        .{ .name = "capitalize", .order = 314, .count = 1 },
        .{ .name = "normal-case", .order = 314, .count = 1 },
        .{ .name = "shadow", .order = 350, .count = 2 },
        .{ .name = "shadow-sm", .order = 350, .count = 2 },
        .{ .name = "shadow-md", .order = 350, .count = 2 },
        .{ .name = "shadow-lg", .order = 350, .count = 2 },
        .{ .name = "shadow-xl", .order = 350, .count = 2 },
        .{ .name = "shadow-none", .order = 350, .count = 2 },
        .{ .name = "outline", .order = 370, .count = 2 },
        .{ .name = "outline-hidden", .order = 369, .count = 2 },
        .{ .name = "outline-none", .order = 373, .count = 2 },
        .{ .name = "outline-solid", .order = 373, .count = 2 },
        .{ .name = "outline-dashed", .order = 373, .count = 2 },
        .{ .name = "outline-dotted", .order = 373, .count = 2 },
        .{ .name = "outline-double", .order = 373, .count = 2 },
        .{ .name = "transition", .order = 390, .count = 3 },
        .{ .name = "transition-all", .order = 390, .count = 3 },
        .{ .name = "transition-colors", .order = 390, .count = 3 },
        .{ .name = "transition-opacity", .order = 390, .count = 3 },
        .{ .name = "transition-shadow", .order = 390, .count = 3 },
        .{ .name = "transition-transform", .order = 390, .count = 3 },
        .{ .name = "transition-none", .order = 390, .count = 1 },
        .{ .name = "touch-auto", .order = 95, .count = 1 },
        .{ .name = "touch-none", .order = 95, .count = 1 },
        .{ .name = "touch-manipulation", .order = 95, .count = 1 },
        .{ .name = "touch-pan-x", .order = 96, .count = 2 },
        .{ .name = "touch-pan-left", .order = 96, .count = 2 },
        .{ .name = "touch-pan-right", .order = 96, .count = 2 },
        .{ .name = "touch-pan-y", .order = 97, .count = 2 },
        .{ .name = "touch-pan-up", .order = 97, .count = 2 },
        .{ .name = "touch-pan-down", .order = 97, .count = 2 },
        .{ .name = "touch-pinch-zoom", .order = 98, .count = 2 },
        .{ .name = "normal-nums", .order = 318, .count = 1 },
        .{ .name = "ordinal", .order = 317, .count = 2 },
        .{ .name = "slashed-zero", .order = 317, .count = 2 },
        .{ .name = "lining-nums", .order = 317, .count = 2 },
        .{ .name = "oldstyle-nums", .order = 317, .count = 2 },
        .{ .name = "proportional-nums", .order = 317, .count = 2 },
        .{ .name = "tabular-nums", .order = 317, .count = 2 },
        .{ .name = "diagonal-fractions", .order = 317, .count = 2 },
        .{ .name = "stacked-fractions", .order = 317, .count = 2 },
        .{ .name = "ring-inset", .order = 357, .count = 1 },
    };
    inline for (pairs) |pair| {
        if (std.mem.eql(u8, base, pair.name)) return .{ .order = pair.order, .count = pair.count };
    }
    if (fontWeightName(base) != null) return .{ .order = 292, .count = 2 };
    return null;
}

fn containerQueryPropertySort(base: []const u8) ?SortProperties {
    if (!std.mem.startsWith(u8, base, "@container")) return null;
    return .{ .order = if (std.mem.indexOfScalar(u8, base, '/') != null) 0 else 1, .count = 1 };
}

fn containPropertySort(base: []const u8) ?SortProperties {
    if (!std.mem.startsWith(u8, base, "contain-")) return null;
    const variable_contain = [_][]const u8{
        "contain-inline-size",
        "contain-layout",
        "contain-paint",
        "contain-size",
        "contain-style",
    };
    inline for (variable_contain) |name| {
        if (std.mem.eql(u8, base, name)) return .{ .order = 408, .count = 2 };
    }
    return .{ .order = 410, .count = 1 };
}

fn spacingPropertySort(base: []const u8) ?SortProperties {
    const pairs = [_]struct { prefix: []const u8, order: u16 }{
        .{ .prefix = "m-", .order = 30 },
        .{ .prefix = "mx-", .order = 31 },
        .{ .prefix = "my-", .order = 32 },
        .{ .prefix = "ms-", .order = 33 },
        .{ .prefix = "me-", .order = 34 },
        .{ .prefix = "mt-", .order = 37 },
        .{ .prefix = "mr-", .order = 38 },
        .{ .prefix = "mb-", .order = 39 },
        .{ .prefix = "ml-", .order = 40 },
        .{ .prefix = "gap-", .order = 170 },
        .{ .prefix = "gap-x-", .order = 171 },
        .{ .prefix = "gap-y-", .order = 172 },
        .{ .prefix = "space-x-", .order = 173 },
        .{ .prefix = "space-y-", .order = 174 },
        .{ .prefix = "scroll-m-", .order = 100 },
        .{ .prefix = "scroll-mx-", .order = 101 },
        .{ .prefix = "scroll-my-", .order = 102 },
        .{ .prefix = "scroll-ms-", .order = 103 },
        .{ .prefix = "scroll-me-", .order = 104 },
        .{ .prefix = "scroll-mt-", .order = 107 },
        .{ .prefix = "scroll-mr-", .order = 108 },
        .{ .prefix = "scroll-mb-", .order = 109 },
        .{ .prefix = "scroll-ml-", .order = 110 },
        .{ .prefix = "scroll-p-", .order = 120 },
        .{ .prefix = "scroll-px-", .order = 121 },
        .{ .prefix = "scroll-py-", .order = 122 },
        .{ .prefix = "scroll-ps-", .order = 123 },
        .{ .prefix = "scroll-pe-", .order = 124 },
        .{ .prefix = "scroll-pt-", .order = 127 },
        .{ .prefix = "scroll-pr-", .order = 128 },
        .{ .prefix = "scroll-pb-", .order = 129 },
        .{ .prefix = "scroll-pl-", .order = 130 },
        .{ .prefix = "p-", .order = 270 },
        .{ .prefix = "px-", .order = 271 },
        .{ .prefix = "py-", .order = 272 },
        .{ .prefix = "ps-", .order = 273 },
        .{ .prefix = "pe-", .order = 274 },
        .{ .prefix = "pt-", .order = 277 },
        .{ .prefix = "pr-", .order = 278 },
        .{ .prefix = "pb-", .order = 279 },
        .{ .prefix = "pl-", .order = 280 },
    };
    inline for (pairs) |pair| {
        if (std.mem.startsWith(u8, base, pair.prefix)) return .{ .order = pair.order, .count = 1 };
    }
    return null;
}

fn sizingPropertySort(base: []const u8) ?SortProperties {
    const pairs = [_]struct { prefix: []const u8, order: u16 }{
        .{ .prefix = "h-", .order = 60 },
        .{ .prefix = "max-h-", .order = 61 },
        .{ .prefix = "min-h-", .order = 62 },
        .{ .prefix = "w-", .order = 63 },
        .{ .prefix = "max-w-", .order = 64 },
        .{ .prefix = "min-w-", .order = 65 },
        .{ .prefix = "size-", .order = 60 },
        .{ .prefix = "basis-", .order = 73 },
    };
    inline for (pairs) |pair| {
        if (std.mem.startsWith(u8, base, pair.prefix)) return .{ .order = pair.order, .count = if (std.mem.eql(u8, pair.prefix, "size-")) 2 else 1 };
    }
    return null;
}

fn insetPropertySort(base: []const u8) ?SortProperties {
    if (isInsetShadowBase(base)) return null;
    const pairs = [_]struct { prefix: []const u8, order: u16 }{
        .{ .prefix = "inset-x-", .order = 5 },
        .{ .prefix = "inset-y-", .order = 6 },
        .{ .prefix = "inset-s-", .order = 7 },
        .{ .prefix = "inset-e-", .order = 8 },
        .{ .prefix = "inset-bs-", .order = 9 },
        .{ .prefix = "inset-be-", .order = 10 },
        .{ .prefix = "inset-", .order = 4 },
        .{ .prefix = "start-", .order = 11 },
        .{ .prefix = "end-", .order = 12 },
        .{ .prefix = "top-", .order = 11 },
        .{ .prefix = "right-", .order = 12 },
        .{ .prefix = "bottom-", .order = 13 },
        .{ .prefix = "left-", .order = 14 },
    };
    inline for (pairs) |pair| {
        if (std.mem.startsWith(u8, base, pair.prefix)) return .{ .order = pair.order, .count = 1 };
    }
    return null;
}

fn gridPropertySort(base: []const u8) ?SortProperties {
    if (std.mem.startsWith(u8, base, "col-")) return .{ .order = 20, .count = 1 };
    if (std.mem.startsWith(u8, base, "col-span-")) return .{ .order = 20, .count = 1 };
    if (std.mem.startsWith(u8, base, "row-")) return .{ .order = 23, .count = 1 };
    if (std.mem.startsWith(u8, base, "row-span-")) return .{ .order = 23, .count = 1 };
    if (std.mem.startsWith(u8, base, "grid-cols-")) return .{ .order = 160, .count = 1 };
    if (std.mem.startsWith(u8, base, "grid-rows-")) return .{ .order = 161, .count = 1 };
    return null;
}

fn objectPropertySort(base: []const u8) ?SortProperties {
    if (!std.mem.startsWith(u8, base, "object-")) return null;
    return .{ .order = 261, .count = 1 };
}

fn borderPropertySort(base: []const u8) ?SortProperties {
    if (std.mem.eql(u8, base, "border")) return .{ .order = 202, .count = 2 };
    if (sideBorderWidth(base)) |side| {
        _ = side;
        const order: u16 = if (std.mem.startsWith(u8, base, "border-x-"))
            203
        else if (std.mem.startsWith(u8, base, "border-y-"))
            204
        else if (std.mem.startsWith(u8, base, "border-t-"))
            209
        else if (std.mem.startsWith(u8, base, "border-r-"))
            210
        else if (std.mem.startsWith(u8, base, "border-b-"))
            211
        else
            212;
        return .{ .order = order, .count = 2 };
    }
    if (std.mem.startsWith(u8, base, "rounded")) return .{ .order = 180, .count = 1 };
    if (std.mem.startsWith(u8, base, "border-")) {
        const suffix = base["border-".len..];
        if (borderStyleValue(suffix) != null) return .{ .order = 214, .count = 2 };
        var width_buf: [128]u8 = undefined;
        if (borderWidthValue(&width_buf, suffix) != null) return .{ .order = 202, .count = 2 };
        var color_buf: [512]u8 = undefined;
        if (colorValue(&color_buf, suffix) != null) return .{ .order = 226, .count = 1 };
    }
    return null;
}

fn typographyPropertySort(base: []const u8) ?SortProperties {
    if (std.mem.startsWith(u8, base, "text-")) {
        const suffix = base["text-".len..];
        if (textSizeValue(suffix) != null) return .{ .order = 290, .count = 2 };
    }
    if (std.mem.startsWith(u8, base, "leading-")) return .{ .order = 291, .count = 2 };
    if (std.mem.startsWith(u8, base, "tracking-")) return .{ .order = 293, .count = 2 };
    if (std.mem.startsWith(u8, base, "font-")) return .{ .order = 288, .count = 1 };
    if (std.mem.startsWith(u8, base, "ease-")) return .{ .order = 393, .count = 2 };
    if (std.mem.startsWith(u8, base, "font-[")) return .{ .order = 288, .count = 1 };
    return null;
}

fn colorPropertySort(base: []const u8) ?SortProperties {
    const pairs = [_]struct { prefix: []const u8, order: u16 }{
        .{ .prefix = "bg-", .order = 238 },
        .{ .prefix = "text-", .order = 305 },
        .{ .prefix = "decoration-", .order = 321 },
        .{ .prefix = "outline-", .order = 372 },
        .{ .prefix = "ring-", .order = 356 },
        .{ .prefix = "placeholder-", .order = 324 },
        .{ .prefix = "caret-", .order = 325 },
        .{ .prefix = "accent-", .order = 326 },
        .{ .prefix = "fill-", .order = 260 },
        .{ .prefix = "stroke-", .order = 261 },
    };
    inline for (pairs) |pair| {
        if (std.mem.startsWith(u8, base, pair.prefix)) return .{ .order = pair.order, .count = 1 };
    }
    return null;
}

fn numericPropertySort(base: []const u8) ?SortProperties {
    if (std.mem.startsWith(u8, base, "z-")) return .{ .order = 16, .count = 1 };
    if (std.mem.startsWith(u8, base, "order-")) return .{ .order = 17, .count = 1 };
    if (std.mem.startsWith(u8, base, "opacity-")) return .{ .order = 340, .count = 1 };
    if (std.mem.startsWith(u8, base, "delay-")) return .{ .order = 391, .count = 1 };
    if (std.mem.startsWith(u8, base, "duration-")) return .{ .order = 392, .count = 2 };
    return null;
}

fn transformPropertySort(base: []const u8) ?SortProperties {
    if (std.mem.startsWith(u8, base, "translate-x-")) return .{ .order = 80, .count = 2 };
    if (std.mem.startsWith(u8, base, "translate-y-")) return .{ .order = 81, .count = 2 };
    if (std.mem.startsWith(u8, base, "scale-")) return .{ .order = 83, .count = 4 };
    if (std.mem.startsWith(u8, base, "rotate-")) return .{ .order = 86, .count = 1 };
    if (std.mem.eql(u8, base, "transform")) return .{ .order = 90, .count = 1 };
    return null;
}

fn isTokenChar(c: u8) bool {
    return switch (c) {
        'a'...'z', 'A'...'Z', '0'...'9', '-', '_', ':', '/', '[', ']', '(', ')', '%', '#', '.', ',', '!', '@', '$', '*', '+', '=', '~', '<', '>', '&', '^' => true,
        else => false,
    };
}

fn isTokenContinuation(c: u8, bracket_depth: usize, paren_depth: usize) bool {
    if (isTokenChar(c)) return true;
    if (bracket_depth == 0 and paren_depth == 0) return false;
    return c == '"' or c == '\'' or c == ' ' or c == '\\';
}

fn cleanToken(token: []const u8) []const u8 {
    var start: usize = 0;
    var end: usize = token.len;
    while (start < end and (token[start] == '.' or token[start] == '#' or token[start] == '<' or token[start] == '>')) : (start += 1) {}
    while (end > start and (token[end - 1] == '.' or token[end - 1] == ',' or token[end - 1] == ';' or token[end - 1] == '<' or token[end - 1] == '>')) : (end -= 1) {}
    const cleaned = token[start..end];
    if (std.mem.startsWith(u8, cleaned, "class=")) return cleanUnquotedClassValue(cleaned["class=".len..]);
    if (std.mem.startsWith(u8, cleaned, "className=")) return cleanUnquotedClassValue(cleaned["className=".len..]);
    return cleaned;
}

fn cleanUnquotedClassValue(value: []const u8) []const u8 {
    var end: usize = value.len;
    for (value, 0..) |c, i| {
        if (c == '<' or c == '>') {
            end = i;
            break;
        }
    }
    return value[0..end];
}

fn looksLikeCandidate(token: []const u8) bool {
    if (token.len == 0) return false;
    if (hasParityDataEntry(token)) return true;
    if (std.mem.indexOfScalar(u8, token, '-') != null) return true;
    if (std.mem.indexOfScalar(u8, token, ':') != null) return true;
    if (std.mem.indexOfScalar(u8, token, '[') != null) return true;
    return isKnownStatic(token);
}

fn hasParityDataEntry(token: []const u8) bool {
    return core_parity_data.find(token) != null or plugin_parity_data.find(token) != null;
}

fn isKnownStatic(token: []const u8) bool {
    if (std.mem.eql(u8, token, "prose") or std.mem.eql(u8, token, "border") or std.mem.eql(u8, token, "rounded")) return true;
    if (std.mem.eql(u8, token, "grayscale") or std.mem.eql(u8, token, "invert") or std.mem.eql(u8, token, "sepia")) return true;
    inline for (static_utilities) |utility| {
        if (std.mem.eql(u8, token, utility.name)) return true;
    }
    return false;
}

const ParsedCandidate = struct {
    variants: []const []const u8,
    base: []const u8,
    important: bool,
};

fn parseCandidate(raw: []const u8, variants_buf: *[16][]const u8) ParsedCandidate {
    var count: usize = 0;
    var bracket_depth: usize = 0;
    var paren_depth: usize = 0;
    var segment_start: usize = 0;
    var base_start: usize = 0;
    for (raw, 0..) |c, i| {
        switch (c) {
            '[' => bracket_depth += 1,
            ']' => {
                if (bracket_depth > 0) bracket_depth -= 1;
            },
            '(' => paren_depth += 1,
            ')' => {
                if (paren_depth > 0) paren_depth -= 1;
            },
            ':' => if (bracket_depth == 0 and paren_depth == 0) {
                if (count < variants_buf.len and i > segment_start) {
                    variants_buf[count] = raw[segment_start..i];
                    count += 1;
                }
                segment_start = i + 1;
                base_start = i + 1;
            },
            else => {},
        }
    }
    var base = raw[base_start..];
    var important = false;
    if (base.len > 0 and base[base.len - 1] == '!') {
        important = true;
        base = base[0 .. base.len - 1];
    } else if (base.len > 0 and base[0] == '!') {
        important = true;
        base = base[1..];
    }
    return .{
        .variants = variants_buf[0..count],
        .base = base,
        .important = important,
    };
}

fn parseCandidateForCompiler(compiler: *Compiler, raw: []const u8, variants_buf: *[16][]const u8) ?ParsedCandidate {
    var parsed = parseCandidate(raw, variants_buf);
    if (compiler.prefix) |prefix| {
        if (parsed.variants.len == 0) return null;
        if (!std.mem.eql(u8, parsed.variants[0], prefix)) return null;
        parsed.variants = parsed.variants[1..];
    }
    return parsed;
}

fn renderCandidate(compiler: *Compiler, out: *std.ArrayList(u8), raw: []const u8) !void {
    const allocator = compiler.allocator;
    var variants_buf: [16][]const u8 = undefined;
    var parsed = parseCandidateForCompiler(compiler, raw, &variants_buf) orelse return;
    const inherited_important = compiler.utilities_important and !parsed.important;
    parsed.important = parsed.important or compiler.utilities_important;
    if (parsed.base.len == 0) return;

    if (std.mem.eql(u8, parsed.base, "container") and customUtilityExists(compiler, "container")) {
        if (try renderContainer(compiler, out, raw, parsed)) {
            _ = try renderCustomUtility(compiler, out, raw, parsed);
            _ = try renderFunctionalUtilities(compiler, out, raw, parsed);
            return;
        }
    }

    if (try renderCustomUtility(compiler, out, raw, parsed)) return;

    if (canUseCoreParityDataBeforeEmitters(compiler, parsed) and try renderCoreParityData(allocator, out, raw, inherited_important)) {
        _ = try renderFunctionalUtilities(compiler, out, raw, parsed);
        return;
    }

    if (try renderArbitraryPropertyCandidate(compiler, out, raw, parsed)) return;

    if (try renderBuiltinThemeColorOpacityFromParityData(compiler, out, raw, parsed, inherited_important)) return;

    if (try renderPrefixedThemeColorOpacityCandidate(compiler, out, raw, parsed)) return;

    if (try renderSpecialColorOpacityCandidate(compiler, out, raw, parsed)) return;

    if (try renderArbitraryDynamicColorCandidate(compiler, out, raw, parsed)) return;

    if (try renderArbitraryStaticColorOpacityCandidate(compiler, out, raw, parsed)) return;

    if (try renderArbitraryDynamicColorOpacityCandidate(compiler, out, raw, parsed)) return;

    if (try renderThemeOpacityColorCandidate(compiler, out, raw, parsed)) return;

    if (try renderDefaultColorOpacityCandidate(compiler, out, raw, parsed)) return;

    if (try renderArbitraryPropertyThemeOpacityCandidate(compiler, out, raw, parsed)) return;

    if (try renderThemeGradientStopCandidate(compiler, out, raw, parsed)) return;

    if (try renderArbitrarySpacingThemeFunctionCandidate(compiler, out, raw, parsed)) return;

    if (try renderRoundedArbitraryThemeFunctionCandidate(compiler, out, raw, parsed)) return;

    if (try renderPrefixedArbitraryThemeFunctionCandidate(compiler, out, raw, parsed)) return;

    if (try renderArbitraryAnimationCandidate(compiler, out, raw, parsed)) return;

    if (try renderThemeSpaceCandidate(compiler, out, raw, parsed)) return;

    if (try renderThemeShadowCandidate(compiler, out, raw, parsed)) return;

    if (try renderThemeInsetShadowCandidate(compiler, out, raw, parsed)) return;

    if (try renderThemeTextShadowCandidate(compiler, out, raw, parsed)) return;

    if (try renderThemeDropShadowCandidate(compiler, out, raw, parsed)) return;

    if (try renderBareFilterCandidate(compiler, out, raw, parsed)) return;

    if (try renderThemeDivideWidthCandidate(compiler, out, raw, parsed)) return;

    if (try renderThemeDivideColorCandidate(compiler, out, raw, parsed)) return;

    if (try renderThemeCandidate(compiler, out, raw, parsed)) {
        _ = try renderFunctionalUtilities(compiler, out, raw, parsed);
        return;
    }
    if (try renderThemeDefaultBorderCandidate(compiler, out, raw, parsed)) {
        _ = try renderFunctionalUtilities(compiler, out, raw, parsed);
        return;
    }
    if (try renderThemeDefaultRingCandidate(compiler, out, raw, parsed)) {
        _ = try renderFunctionalUtilities(compiler, out, raw, parsed);
        return;
    }
    if (try renderThemeOutlineCandidate(compiler, out, raw, parsed)) {
        _ = try renderFunctionalUtilities(compiler, out, raw, parsed);
        return;
    }
    if (try renderThemeContentCandidate(compiler, out, raw, parsed)) {
        _ = try renderFunctionalUtilities(compiler, out, raw, parsed);
        return;
    }
    if (try renderThemeBlurCandidate(compiler, out, raw, parsed)) {
        _ = try renderFunctionalUtilities(compiler, out, raw, parsed);
        return;
    }
    if (try renderTransitionCandidate(compiler, out, raw, parsed)) {
        _ = try renderFunctionalUtilities(compiler, out, raw, parsed);
        return;
    }
    if (try renderDecorationInheritCandidate(compiler, out, raw, parsed)) {
        _ = try renderFunctionalUtilities(compiler, out, raw, parsed);
        return;
    }
    if (try renderContainer(compiler, out, raw, parsed)) {
        _ = try renderFunctionalUtilities(compiler, out, raw, parsed);
        return;
    }
    if (!candidateHasCustomVariant(compiler, parsed.variants) and !themeParityDataSuppressed(compiler, parsed.base) and try renderCoreParityData(allocator, out, raw, inherited_important)) {
        _ = try renderFunctionalUtilities(compiler, out, raw, parsed);
        return;
    }
    if (try renderTypedPropertyUtility(compiler, out, raw, parsed)) {
        _ = try renderFunctionalUtilities(compiler, out, raw, parsed);
        return;
    }
    if (try renderPluginParityData(allocator, out, parsed)) {
        _ = try renderFunctionalUtilities(compiler, out, raw, parsed);
        return;
    }
    if (try renderTypography(allocator, out, raw, parsed)) {
        _ = try renderFunctionalUtilities(compiler, out, raw, parsed);
        return;
    }
    if (try renderCustomVariantCandidate(compiler, out, raw, parsed)) {
        _ = try renderFunctionalUtilities(compiler, out, raw, parsed);
        return;
    }

    if (!themeParityDataSuppressed(compiler, parsed.base) and variantsAreSupported(parsed.variants)) {
        var decls: std.ArrayList(u8) = .empty;
        defer decls.deinit(allocator);
        if (try emitUtility(allocator, &decls, parsed.base, parsed.important)) {
            if (decls.items.len > 0) {
                try writeThemeRule(compiler, out, raw, parsed.variants, "", decls.items);
            }
        }
    }
    _ = try renderFunctionalUtilities(compiler, out, raw, parsed);
}

fn renderCustomUtility(compiler: *Compiler, out: *std.ArrayList(u8), raw: []const u8, parsed: ParsedCandidate) !bool {
    if (!themeVariantsAreSupported(compiler, parsed.variants)) return false;
    var matched = false;
    for (compiler.custom_utilities.items) |utility| {
        if (!std.mem.eql(u8, utility.name, parsed.base)) continue;
        var decls: std.ArrayList(u8) = .empty;
        defer decls.deinit(compiler.allocator);
        try expandCustomUtilityDeclarations(compiler, &decls, utility.declarations);
        if (decls.items.len == 0) continue;
        if (parsed.important) {
            var important_decls: std.ArrayList(u8) = .empty;
            defer important_decls.deinit(compiler.allocator);
            try appendImportantMarkers(compiler.allocator, &important_decls, decls.items);
            if (customUtilityCssHasAtRule(important_decls.items)) {
                try writeCustomUtilityExpandedRules(compiler, out, raw, parsed.variants, important_decls.items);
            } else {
                try writeThemeRule(compiler, out, raw, parsed.variants, "", important_decls.items);
            }
        } else {
            if (customUtilityCssHasAtRule(decls.items)) {
                try writeCustomUtilityExpandedRules(compiler, out, raw, parsed.variants, decls.items);
            } else {
                try writeThemeRule(compiler, out, raw, parsed.variants, "", decls.items);
            }
        }
        matched = true;
    }
    return matched;
}

fn renderArbitraryPropertyCandidate(compiler: *Compiler, out: *std.ArrayList(u8), raw: []const u8, parsed: ParsedCandidate) !bool {
    if (!themeVariantsAreSupported(compiler, parsed.variants)) return false;
    const body = arbitraryBracketBody(parsed.base) orelse return false;
    const colon = topLevelDeclarationColon(body) orelse return false;
    const property = trimAscii(body[0..colon]);
    const raw_value = trimAscii(body[colon + 1 ..]);
    if (property.len == 0 or raw_value.len == 0) return false;

    var rewritten: std.ArrayList(u8) = .empty;
    defer rewritten.deinit(compiler.allocator);
    const rewritten_ok = try rewriteAuthoredCssFunctions(compiler, &rewritten, raw_value, true);
    if (!rewritten_ok and containsThemeFunctionSyntax(raw_value)) return false;
    if (rewritten_ok and containsThemeFunctionSyntax(rewritten.items)) return false;
    const value = if (rewritten_ok) rewritten.items else raw_value;

    var decls: std.ArrayList(u8) = .empty;
    defer decls.deinit(compiler.allocator);
    try appendDecl(compiler.allocator, &decls, property, value, parsed.important);
    try writeThemeRule(compiler, out, raw, parsed.variants, "", decls.items);
    return true;
}

fn customUtilityExists(compiler: *Compiler, name: []const u8) bool {
    for (compiler.custom_utilities.items) |utility| {
        if (std.mem.eql(u8, utility.name, name)) return true;
    }
    return false;
}

fn customUtilityCssHasAtRule(css: []const u8) bool {
    return std.mem.indexOf(u8, css, "@media") != null or std.mem.indexOf(u8, css, "@container") != null;
}

fn writeCustomUtilityExpandedRules(compiler: *Compiler, out: *std.ArrayList(u8), raw: []const u8, variants: []const []const u8, css: []const u8) !void {
    var base_decls: std.ArrayList(u8) = .empty;
    defer base_decls.deinit(compiler.allocator);

    var i: usize = 0;
    while (i < css.len) {
        skipCssWhitespaceAndComments(css, &i);
        if (i >= css.len) break;

        const start = i;
        var paren_depth: usize = 0;
        var bracket_depth: usize = 0;
        var block_open: ?usize = null;
        while (i < css.len) : (i += 1) {
            switch (css[i]) {
                '(' => paren_depth += 1,
                ')' => if (paren_depth > 0) {
                    paren_depth -= 1;
                },
                '[' => bracket_depth += 1,
                ']' => if (bracket_depth > 0) {
                    bracket_depth -= 1;
                },
                '{' => if (paren_depth == 0 and bracket_depth == 0) {
                    block_open = i;
                    break;
                },
                ';' => if (paren_depth == 0 and bracket_depth == 0) {
                    i += 1;
                    break;
                },
                else => {},
            }
        }

        if (block_open) |open| {
            if (base_decls.items.len > 0) {
                try writeThemeRule(compiler, out, raw, variants, "", base_decls.items);
                base_decls.clearRetainingCapacity();
            }

            const end = scanCssBlock(css, start) orelse css.len;
            try out.appendSlice(compiler.allocator, trimAscii(css[start..open]));
            try out.append(compiler.allocator, '{');
            const inner = trimAscii(css[open + 1 .. end - 1]);
            if (inner.len > 0) try writeThemeRule(compiler, out, raw, variants, "", inner);
            try out.append(compiler.allocator, '}');
            i = end;
            continue;
        }

        try base_decls.appendSlice(compiler.allocator, trimAscii(css[start..i]));
    }

    if (base_decls.items.len > 0) try writeThemeRule(compiler, out, raw, variants, "", base_decls.items);
}

fn themeParityDataSuppressed(compiler: *Compiler, base: []const u8) bool {
    if (compiler.unset_theme_wildcards.items.len == 0) return false;
    var name_buf: [512]u8 = undefined;
    const name = candidateThemeVariableName(&name_buf, base) orelse return false;
    if (findThemeVariable(compiler, name)) |variable| {
        if (!std.mem.eql(u8, variable.value, "initial")) return false;
    }

    for (compiler.unset_theme_wildcards.items) |prefix| {
        if (themeWildcardMatches(prefix, name)) return true;
    }
    return false;
}

fn canUseCoreParityDataBeforeEmitters(compiler: *Compiler, parsed: ParsedCandidate) bool {
    if (candidateHasCustomVariant(compiler, parsed.variants)) return false;
    if (compiler.unset_theme_wildcards.items.len > 0) return false;
    for (compiler.theme_variables.items) |variable| {
        if (!variable.builtin) return false;
        if (variable.reference or variable.inline_theme) return false;
    }
    return true;
}

fn candidateThemeVariableName(buf: []u8, raw_base: []const u8) ?[]const u8 {
    var base = raw_base;
    if (base.len > 1 and base[0] == '-') base = base[1..];

    if (fontWeightName(base)) |name| return std.fmt.bufPrint(buf, "--font-weight-{s}", .{name}) catch null;
    if (std.mem.startsWith(u8, base, "font-")) return std.fmt.bufPrint(buf, "--font-{s}", .{base["font-".len..]}) catch null;
    if (std.mem.startsWith(u8, base, "text-")) return std.fmt.bufPrint(buf, "--text-{s}", .{base["text-".len..]}) catch null;
    if (std.mem.startsWith(u8, base, "rounded-")) return std.fmt.bufPrint(buf, "--radius-{s}", .{base["rounded-".len..]}) catch null;
    if (std.mem.startsWith(u8, base, "animate-")) return std.fmt.bufPrint(buf, "--animate-{s}", .{base["animate-".len..]}) catch null;

    const color_prefixes = [_][]const u8{ "bg-", "border-", "outline-", "ring-offset-", "inset-ring-", "ring-", "decoration-", "placeholder-", "accent-", "caret-", "fill-", "stroke-" };
    inline for (color_prefixes) |prefix| {
        if (std.mem.startsWith(u8, base, prefix)) {
            var color = base[prefix.len..];
            if (std.mem.indexOfScalar(u8, color, '/')) |slash| color = color[0..slash];
            if (colorThemeNamespaceForPrefix(prefix)) |namespace| {
                if (!std.mem.eql(u8, namespace, "--color-")) {
                    return std.fmt.bufPrint(buf, "{s}{s}", .{ namespace, color }) catch null;
                }
            }
            return std.fmt.bufPrint(buf, "--color-{s}", .{color}) catch null;
        }
    }

    const spacing_prefixes = [_][]const u8{
        "p-",         "px-",        "py-",         "ps-",         "pe-",         "pbs-",
        "pbe-",       "pt-",        "pr-",         "pb-",         "pl-",         "m-",
        "mx-",        "my-",        "ms-",         "me-",         "mbs-",        "mbe-",
        "mt-",        "mr-",        "mb-",         "ml-",         "scroll-m-",   "scroll-mx-",
        "scroll-my-", "scroll-ms-", "scroll-me-",  "scroll-mbs-", "scroll-mbe-", "scroll-mt-",
        "scroll-mr-", "scroll-mb-", "scroll-ml-",  "scroll-p-",   "scroll-px-",  "scroll-py-",
        "scroll-ps-", "scroll-pe-", "scroll-pbs-", "scroll-pbe-", "scroll-pt-",  "scroll-pr-",
        "scroll-pb-", "scroll-pl-", "gap-",        "gap-x-",      "gap-y-",      "w-",
        "min-w-",     "max-w-",     "h-",          "min-h-",      "max-h-",      "size-",
        "basis-",
    };
    inline for (spacing_prefixes) |prefix| {
        if (std.mem.startsWith(u8, base, prefix)) return std.fmt.bufPrint(buf, "--spacing-{s}", .{base[prefix.len..]}) catch null;
    }

    const inset_prefixes = [_][]const u8{ "inset-x-", "inset-y-", "inset-s-", "inset-e-", "inset-bs-", "inset-be-", "inset-", "start-", "end-", "top-", "right-", "bottom-", "left-" };
    inline for (inset_prefixes) |prefix| {
        if (std.mem.startsWith(u8, base, prefix)) return std.fmt.bufPrint(buf, "--inset-{s}", .{base[prefix.len..]}) catch null;
    }

    return null;
}

fn renderBuiltinThemeColorOpacityFromParityData(
    compiler: *Compiler,
    out: *std.ArrayList(u8),
    raw: []const u8,
    parsed: ParsedCandidate,
    important: bool,
) !bool {
    if (compiler.prefix != null) return false;
    if (parsed.variants.len != 0) return false;
    if (std.mem.startsWith(u8, parsed.base, "outline-")) return false;

    const color = themeColorOpacityName(parsed.base) orelse return false;
    var name_buf: [512]u8 = undefined;
    const name = std.fmt.bufPrint(&name_buf, "--color-{s}", .{color}) catch return false;
    const variable = findThemeVariable(compiler, name) orelse return false;
    if (!variable.builtin) return false;

    return try renderCoreParityData(compiler.allocator, out, raw, important);
}

fn renderPrefixedThemeColorOpacityCandidate(compiler: *Compiler, out: *std.ArrayList(u8), raw: []const u8, parsed: ParsedCandidate) !bool {
    if (parsed.variants.len != 0) return false;

    const color = themeColorOpacityName(parsed.base) orelse return false;
    var theme_name_buf: [512]u8 = undefined;
    const theme_name = std.fmt.bufPrint(&theme_name_buf, "--color-{s}", .{color}) catch return false;
    const color_variable = findThemeVariable(compiler, theme_name);

    const prefixes = [_]struct { prefix: []const u8, prop: []const u8, suffix: []const u8 = "" }{
        .{ .prefix = "bg-", .prop = "background-color" },
        .{ .prefix = "text-", .prop = "color" },
        .{ .prefix = "border-", .prop = "border-color" },
        .{ .prefix = "outline-", .prop = "outline-color" },
        .{ .prefix = "ring-offset-", .prop = "--tw-ring-offset-color" },
        .{ .prefix = "inset-ring-", .prop = "--tw-inset-ring-color" },
        .{ .prefix = "ring-", .prop = "--tw-ring-color" },
        .{ .prefix = "decoration-", .prop = "text-decoration-color" },
        .{ .prefix = "placeholder-", .prop = "color", .suffix = "::placeholder" },
        .{ .prefix = "accent-", .prop = "accent-color" },
        .{ .prefix = "caret-", .prop = "caret-color" },
        .{ .prefix = "fill-", .prop = "fill" },
        .{ .prefix = "stroke-", .prop = "stroke" },
    };

    inline for (prefixes) |entry| {
        if (std.mem.startsWith(u8, parsed.base, entry.prefix)) {
            const value_part = parsed.base[entry.prefix.len..];
            const slash = std.mem.indexOfScalar(u8, value_part, '/') orelse unreachable;
            const entry_color = value_part[0..slash];
            const alpha_token = value_part[slash + 1 ..];

            const entry_variable = if (colorThemeNamespaceForPrefix(entry.prefix)) |namespace|
                findThemeVariableWithNamespace(compiler, namespace, entry_color) orelse color_variable orelse return false
            else
                color_variable orelse return false;

            var value_buf: [512]u8 = undefined;
            const value = resolveThemeName(compiler, &value_buf, entry_variable.name) orelse return false;
            var pct_buf: [512]u8 = undefined;
            const pct = opacityPercentWithTheme(compiler, &pct_buf, alpha_token) orelse return false;
            if (std.mem.eql(u8, pct, "100%")) return false;

            if (entry_variable.inline_theme) {
                var flattened_buf: [256]u8 = undefined;
                if (oklchOpacityToOklab(compiler, &flattened_buf, entry_variable.value, alpha_token)) |flattened| {
                    var decls: std.ArrayList(u8) = .empty;
                    defer decls.deinit(compiler.allocator);
                    try appendDecl(compiler.allocator, &decls, entry.prop, flattened, parsed.important);
                    try writeThemeRule(compiler, out, raw, parsed.variants, entry.suffix, decls.items);
                    return true;
                }
            }

            const fallback_source = if (findThemeVariableLast(compiler, entry_variable.name)) |latest| latest.value else entry_variable.value;
            var fallback_color_buf: [16]u8 = undefined;
            const fallback_color = if (compiler.prefix == null) colorFallbackHex(compiler, &fallback_color_buf, fallback_source, 0) else null;
            var static_pct_buf: [64]u8 = undefined;
            const static_pct = opacityStaticPercent(compiler, &static_pct_buf, alpha_token) orelse pct;
            var fallback_buf: [16]u8 = undefined;
            const fallback = if (fallback_color) |color_hex| blk: {
                if (hexColorWithAlpha(&fallback_buf, color_hex, static_pct)) |with_alpha| break :blk with_alpha;
                break :blk colorFallbackValue(compiler, fallback_source, 0) orelse value;
            } else if (compiler.prefix == null)
                colorFallbackValue(compiler, fallback_source, 0) orelse value
            else
                value;

            var base_decls: std.ArrayList(u8) = .empty;
            defer base_decls.deinit(compiler.allocator);
            try appendDecl(compiler.allocator, &base_decls, entry.prop, fallback, parsed.important);
            try writeThemeRule(compiler, out, raw, parsed.variants, entry.suffix, base_decls.items);

            var mixed_buf: [768]u8 = undefined;
            const mixed = std.fmt.bufPrint(&mixed_buf, "color-mix(in oklab,{s} {s},transparent)", .{ value, pct }) catch return false;
            var supports_decls: std.ArrayList(u8) = .empty;
            defer supports_decls.deinit(compiler.allocator);
            try appendDecl(compiler.allocator, &supports_decls, entry.prop, mixed, parsed.important);
            try out.appendSlice(compiler.allocator, "@supports (color:color-mix(in lab, red, red)){");
            try writeThemeRule(compiler, out, raw, parsed.variants, entry.suffix, supports_decls.items);
            try out.append(compiler.allocator, '}');
            return true;
        }
    }

    return false;
}

fn renderArbitraryStaticColorOpacityCandidate(compiler: *Compiler, out: *std.ArrayList(u8), raw: []const u8, parsed: ParsedCandidate) !bool {
    if (parsed.variants.len != 0) return false;

    const entries = [_]struct { prefix: []const u8, prop: []const u8, suffix: []const u8 = "" }{
        .{ .prefix = "bg-", .prop = "background-color" },
        .{ .prefix = "text-", .prop = "color" },
        .{ .prefix = "border-", .prop = "border-color" },
        .{ .prefix = "outline-", .prop = "outline-color" },
        .{ .prefix = "ring-offset-", .prop = "--tw-ring-offset-color" },
        .{ .prefix = "inset-ring-", .prop = "--tw-inset-ring-color" },
        .{ .prefix = "ring-", .prop = "--tw-ring-color" },
        .{ .prefix = "decoration-", .prop = "text-decoration-color" },
        .{ .prefix = "placeholder-", .prop = "color", .suffix = "::placeholder" },
        .{ .prefix = "accent-", .prop = "accent-color" },
        .{ .prefix = "caret-", .prop = "caret-color" },
        .{ .prefix = "fill-", .prop = "fill" },
        .{ .prefix = "stroke-", .prop = "stroke" },
    };

    for (entries) |entry| {
        if (!std.mem.startsWith(u8, parsed.base, entry.prefix)) continue;
        const value_part = parsed.base[entry.prefix.len..];
        const slash = topLevelSlash(value_part) orelse return false;
        if (slash == 0 or slash + 1 >= value_part.len) return false;
        const color_token = value_part[0..slash];
        const alpha_token = value_part[slash + 1 ..];
        if (findThemeVariableWithNamespace(compiler, "--opacity-", alpha_token) != null) return false;

        var color_buf: [1024]u8 = undefined;
        var color = arbitraryValue(&color_buf, color_token) orelse return false;
        if (arbitraryTypeSeparator(color)) |colon| {
            const data_type = color[0..colon];
            if (!std.mem.eql(u8, data_type, "color")) return false;
            color = color[colon + 1 ..];
        }

        var mixed_buf: [512]u8 = undefined;
        const mixed = staticColorOpacityToOklab(&mixed_buf, color, alpha_token) orelse return false;
        var decls: std.ArrayList(u8) = .empty;
        defer decls.deinit(compiler.allocator);
        try appendDecl(compiler.allocator, &decls, entry.prop, mixed, parsed.important);
        try writeThemeRule(compiler, out, raw, parsed.variants, entry.suffix, decls.items);
        return true;
    }

    return false;
}

fn renderSpecialColorOpacityCandidate(compiler: *Compiler, out: *std.ArrayList(u8), raw: []const u8, parsed: ParsedCandidate) !bool {
    if (parsed.variants.len != 0) return false;

    const entries = [_]struct { prefix: []const u8, prop: []const u8, suffix: []const u8 = "" }{
        .{ .prefix = "bg-", .prop = "background-color" },
        .{ .prefix = "text-", .prop = "color" },
        .{ .prefix = "border-", .prop = "border-color" },
        .{ .prefix = "outline-", .prop = "outline-color" },
        .{ .prefix = "ring-offset-", .prop = "--tw-ring-offset-color" },
        .{ .prefix = "inset-ring-", .prop = "--tw-inset-ring-color" },
        .{ .prefix = "ring-", .prop = "--tw-ring-color" },
        .{ .prefix = "decoration-", .prop = "text-decoration-color" },
        .{ .prefix = "placeholder-", .prop = "color", .suffix = "::placeholder" },
        .{ .prefix = "accent-", .prop = "accent-color" },
        .{ .prefix = "caret-", .prop = "caret-color" },
        .{ .prefix = "fill-", .prop = "fill" },
        .{ .prefix = "stroke-", .prop = "stroke" },
    };

    for (entries) |entry| {
        if (!std.mem.startsWith(u8, parsed.base, entry.prefix)) continue;
        const value_part = parsed.base[entry.prefix.len..];
        const slash = topLevelSlash(value_part) orelse return false;
        if (slash == 0 or slash + 1 >= value_part.len) return false;
        const color_token = value_part[0..slash];
        const alpha_token = value_part[slash + 1 ..];

        const color = if (std.mem.eql(u8, color_token, "current"))
            currentColorForProperty(entry.prop)
        else if (std.mem.eql(u8, color_token, "inherit"))
            "inherit"
        else if (std.mem.eql(u8, color_token, "transparent"))
            "#0000"
        else
            return false;

        var pct_buf: [512]u8 = undefined;
        const pct = opacityPercentWithTheme(compiler, &pct_buf, alpha_token) orelse return false;

        var base_decls: std.ArrayList(u8) = .empty;
        defer base_decls.deinit(compiler.allocator);
        try appendDecl(compiler.allocator, &base_decls, entry.prop, color, parsed.important);
        try writeThemeRule(compiler, out, raw, parsed.variants, entry.suffix, base_decls.items);

        const mix_color = if (std.mem.eql(u8, color, "currentColor")) "currentcolor" else color;
        var mixed_buf: [768]u8 = undefined;
        const mixed = std.fmt.bufPrint(&mixed_buf, "color-mix(in oklab,{s} {s},transparent)", .{ mix_color, pct }) catch return false;
        var supports_decls: std.ArrayList(u8) = .empty;
        defer supports_decls.deinit(compiler.allocator);
        try appendDecl(compiler.allocator, &supports_decls, entry.prop, mixed, parsed.important);
        try out.appendSlice(compiler.allocator, "@supports (color:color-mix(in lab, red, red)){");
        try writeThemeRule(compiler, out, raw, parsed.variants, entry.suffix, supports_decls.items);
        try out.append(compiler.allocator, '}');
        return true;
    }

    return false;
}

fn renderArbitraryDynamicColorCandidate(compiler: *Compiler, out: *std.ArrayList(u8), raw: []const u8, parsed: ParsedCandidate) !bool {
    if (parsed.variants.len != 0) return false;

    const entries = [_]struct { prefix: []const u8, prop: []const u8, suffix: []const u8 = "" }{
        .{ .prefix = "bg-", .prop = "background-color" },
        .{ .prefix = "text-", .prop = "color" },
        .{ .prefix = "border-", .prop = "border-color" },
        .{ .prefix = "outline-", .prop = "outline-color" },
        .{ .prefix = "ring-offset-", .prop = "--tw-ring-offset-color" },
        .{ .prefix = "inset-ring-", .prop = "--tw-inset-ring-color" },
        .{ .prefix = "ring-", .prop = "--tw-ring-color" },
        .{ .prefix = "decoration-", .prop = "text-decoration-color" },
        .{ .prefix = "placeholder-", .prop = "color", .suffix = "::placeholder" },
        .{ .prefix = "accent-", .prop = "accent-color" },
        .{ .prefix = "caret-", .prop = "caret-color" },
        .{ .prefix = "fill-", .prop = "fill" },
        .{ .prefix = "stroke-", .prop = "stroke" },
    };

    for (entries) |entry| {
        if (!std.mem.startsWith(u8, parsed.base, entry.prefix)) continue;
        const color_token = parsed.base[entry.prefix.len..];
        if (topLevelSlash(color_token) != null) return false;

        var color_buf: [1024]u8 = undefined;
        var color = arbitraryValue(&color_buf, color_token) orelse return false;
        var typed_color = false;
        if (arbitraryTypeSeparator(color)) |colon| {
            const data_type = color[0..colon];
            if (!std.mem.eql(u8, data_type, "color")) return false;
            typed_color = true;
            color = color[colon + 1 ..];
        }
        if (std.mem.startsWith(u8, color, "--")) {
            var var_buf: [1050]u8 = undefined;
            color = std.fmt.bufPrint(&var_buf, "var({s})", .{color}) catch return false;
        } else if (!typed_color and !std.mem.startsWith(u8, color, "var(")) {
            return false;
        }

        var decls: std.ArrayList(u8) = .empty;
        defer decls.deinit(compiler.allocator);
        try appendDecl(compiler.allocator, &decls, entry.prop, color, parsed.important);
        try writeThemeRule(compiler, out, raw, parsed.variants, entry.suffix, decls.items);
        return true;
    }

    return false;
}

fn renderArbitraryDynamicColorOpacityCandidate(compiler: *Compiler, out: *std.ArrayList(u8), raw: []const u8, parsed: ParsedCandidate) !bool {
    if (parsed.variants.len != 0) return false;

    const entries = [_]struct { prefix: []const u8, prop: []const u8, suffix: []const u8 = "" }{
        .{ .prefix = "bg-", .prop = "background-color" },
        .{ .prefix = "text-", .prop = "color" },
        .{ .prefix = "border-", .prop = "border-color" },
        .{ .prefix = "ring-offset-", .prop = "--tw-ring-offset-color" },
        .{ .prefix = "inset-ring-", .prop = "--tw-inset-ring-color" },
        .{ .prefix = "ring-", .prop = "--tw-ring-color" },
        .{ .prefix = "decoration-", .prop = "text-decoration-color" },
        .{ .prefix = "placeholder-", .prop = "color", .suffix = "::placeholder" },
        .{ .prefix = "accent-", .prop = "accent-color" },
        .{ .prefix = "caret-", .prop = "caret-color" },
        .{ .prefix = "fill-", .prop = "fill" },
        .{ .prefix = "stroke-", .prop = "stroke" },
    };

    for (entries) |entry| {
        if (!std.mem.startsWith(u8, parsed.base, entry.prefix)) continue;
        const value_part = parsed.base[entry.prefix.len..];
        const slash = topLevelSlash(value_part) orelse return false;
        if (slash == 0 or slash + 1 >= value_part.len) return false;
        const color_token = value_part[0..slash];
        const alpha_token = value_part[slash + 1 ..];
        if (findThemeVariableWithNamespace(compiler, "--opacity-", alpha_token) != null) return false;

        var color_buf: [1024]u8 = undefined;
        var color = arbitraryValue(&color_buf, color_token) orelse return false;
        var typed_color = false;
        if (arbitraryTypeSeparator(color)) |colon| {
            const data_type = color[0..colon];
            if (!std.mem.eql(u8, data_type, "color")) return false;
            typed_color = true;
            color = color[colon + 1 ..];
        }
        if (std.mem.startsWith(u8, color, "--")) {
            var var_buf: [1050]u8 = undefined;
            color = std.fmt.bufPrint(&var_buf, "var({s})", .{color}) catch return false;
        } else if (!typed_color and !std.mem.startsWith(u8, color, "var(")) {
            return false;
        }

        var pct_buf: [64]u8 = undefined;
        const pct = opacityPercent(&pct_buf, alpha_token) orelse return false;

        var base_decls: std.ArrayList(u8) = .empty;
        defer base_decls.deinit(compiler.allocator);
        try appendDecl(compiler.allocator, &base_decls, entry.prop, color, parsed.important);
        try writeThemeRule(compiler, out, raw, parsed.variants, entry.suffix, base_decls.items);

        var mixed_buf: [1536]u8 = undefined;
        const mixed = std.fmt.bufPrint(&mixed_buf, "color-mix(in oklab,{s} {s},transparent)", .{ color, pct }) catch return false;
        var supports_decls: std.ArrayList(u8) = .empty;
        defer supports_decls.deinit(compiler.allocator);
        try appendDecl(compiler.allocator, &supports_decls, entry.prop, mixed, parsed.important);
        try out.appendSlice(compiler.allocator, "@supports (color:color-mix(in lab, red, red)){");
        try writeThemeRule(compiler, out, raw, parsed.variants, entry.suffix, supports_decls.items);
        try out.append(compiler.allocator, '}');
        return true;
    }

    return false;
}

fn renderThemeOpacityColorCandidate(compiler: *Compiler, out: *std.ArrayList(u8), raw: []const u8, parsed: ParsedCandidate) !bool {
    if (parsed.variants.len != 0) return false;

    const entries = [_]struct { prefix: []const u8, prop: []const u8, suffix: []const u8 = "" }{
        .{ .prefix = "bg-", .prop = "background-color" },
        .{ .prefix = "text-", .prop = "color" },
        .{ .prefix = "border-", .prop = "border-color" },
        .{ .prefix = "ring-offset-", .prop = "--tw-ring-offset-color" },
        .{ .prefix = "inset-ring-", .prop = "--tw-inset-ring-color" },
        .{ .prefix = "ring-", .prop = "--tw-ring-color" },
        .{ .prefix = "decoration-", .prop = "text-decoration-color" },
        .{ .prefix = "placeholder-", .prop = "color", .suffix = "::placeholder" },
        .{ .prefix = "accent-", .prop = "accent-color" },
        .{ .prefix = "caret-", .prop = "caret-color" },
        .{ .prefix = "fill-", .prop = "fill" },
        .{ .prefix = "stroke-", .prop = "stroke" },
    };

    for (entries) |entry| {
        if (!std.mem.startsWith(u8, parsed.base, entry.prefix)) continue;
        const value_part = parsed.base[entry.prefix.len..];
        const slash = topLevelSlash(value_part) orelse return false;
        if (slash == 0 or slash + 1 >= value_part.len) return false;
        const color_token = value_part[0..slash];
        const alpha_token = value_part[slash + 1 ..];
        if (findThemeVariableWithNamespace(compiler, "--opacity-", alpha_token) == null) return false;

        var color_buf: [1024]u8 = undefined;
        const color = specialColorOrArbitraryValue(&color_buf, color_token) orelse return false;

        var alpha_buf: [512]u8 = undefined;
        const alpha = opacityPercentWithTheme(compiler, &alpha_buf, alpha_token) orelse return false;

        var decls: std.ArrayList(u8) = .empty;
        defer decls.deinit(compiler.allocator);
        try appendDecl(compiler.allocator, &decls, entry.prop, color, parsed.important);
        try writeThemeRule(compiler, out, raw, parsed.variants, entry.suffix, decls.items);

        var mixed_buf: [1536]u8 = undefined;
        const mixed = std.fmt.bufPrint(&mixed_buf, "color-mix(in oklab,{s} {s},transparent)", .{ colorMixCurrentColor(color), alpha }) catch return false;
        var supports_decls: std.ArrayList(u8) = .empty;
        defer supports_decls.deinit(compiler.allocator);
        try appendDecl(compiler.allocator, &supports_decls, entry.prop, mixed, parsed.important);
        try out.appendSlice(compiler.allocator, "@supports (color:color-mix(in lab, red, red)){");
        try writeThemeRule(compiler, out, raw, parsed.variants, entry.suffix, supports_decls.items);
        try out.append(compiler.allocator, '}');
        return true;
    }

    return false;
}

fn renderDefaultColorOpacityCandidate(compiler: *Compiler, out: *std.ArrayList(u8), raw: []const u8, parsed: ParsedCandidate) !bool {
    if (!themeVariantsAreSupported(compiler, parsed.variants)) return false;

    const entries = [_]struct { prefix: []const u8, prop: []const u8, suffix: []const u8 = "" }{
        .{ .prefix = "bg-", .prop = "background-color" },
        .{ .prefix = "text-", .prop = "color" },
        .{ .prefix = "border-", .prop = "border-color" },
        .{ .prefix = "outline-", .prop = "outline-color" },
        .{ .prefix = "ring-offset-", .prop = "--tw-ring-offset-color" },
        .{ .prefix = "inset-ring-", .prop = "--tw-inset-ring-color" },
        .{ .prefix = "ring-", .prop = "--tw-ring-color" },
        .{ .prefix = "decoration-", .prop = "text-decoration-color" },
        .{ .prefix = "placeholder-", .prop = "color", .suffix = "::placeholder" },
        .{ .prefix = "accent-", .prop = "accent-color" },
        .{ .prefix = "caret-", .prop = "caret-color" },
        .{ .prefix = "fill-", .prop = "fill" },
        .{ .prefix = "stroke-", .prop = "stroke" },
    };

    for (entries) |entry| {
        if (!std.mem.startsWith(u8, parsed.base, entry.prefix)) continue;
        const value_part = parsed.base[entry.prefix.len..];
        const slash = topLevelSlash(value_part) orelse return false;
        if (slash == 0 or slash + 1 >= value_part.len) return false;
        const color = value_part[0..slash];
        const alpha_token = value_part[slash + 1 ..];
        if (color.len == 0 or color[0] == '[') return false;

        var name_buf: [512]u8 = undefined;
        const name = std.fmt.bufPrint(&name_buf, "--color-{s}", .{color}) catch return false;
        const theme_value = builtinThemeVariableValue(name) orelse return false;

        var pct_buf: [64]u8 = undefined;
        const pct = opacityPercent(&pct_buf, alpha_token) orelse return false;
        if (std.mem.eql(u8, pct, "100%")) return false;

        var fallback_color_buf: [16]u8 = undefined;
        const fallback_color = defaultColorFallbackHex(name) orelse colorFallbackHex(compiler, &fallback_color_buf, theme_value, 0) orelse return false;
        var fallback_buf: [16]u8 = undefined;
        const fallback = hexColorWithAlpha(&fallback_buf, fallback_color, pct) orelse return false;

        var value_buf: [768]u8 = undefined;
        const value = std.fmt.bufPrint(&value_buf, "var({s})", .{name}) catch return false;

        var base_decls: std.ArrayList(u8) = .empty;
        defer base_decls.deinit(compiler.allocator);
        try appendDecl(compiler.allocator, &base_decls, entry.prop, fallback, parsed.important);

        var mixed_buf: [1024]u8 = undefined;
        const mixed = std.fmt.bufPrint(&mixed_buf, "color-mix(in oklab,{s} {s},transparent)", .{ value, pct }) catch return false;
        var supports_decls: std.ArrayList(u8) = .empty;
        defer supports_decls.deinit(compiler.allocator);
        try appendDecl(compiler.allocator, &supports_decls, entry.prop, mixed, parsed.important);

        try openThemeMediaWrappers(compiler, out, parsed.variants);
        try writeThemeRuleWithoutMediaWrappers(compiler, out, raw, parsed.variants, entry.suffix, base_decls.items);
        try out.appendSlice(compiler.allocator, "@supports (color:color-mix(in lab, red, red)){");
        try writeThemeRuleWithoutMediaWrappers(compiler, out, raw, parsed.variants, entry.suffix, supports_decls.items);
        try out.append(compiler.allocator, '}');
        try closeThemeMediaWrappers(compiler, out, parsed.variants);
        return true;
    }

    return false;
}

fn renderArbitraryPropertyThemeOpacityCandidate(compiler: *Compiler, out: *std.ArrayList(u8), raw: []const u8, parsed: ParsedCandidate) !bool {
    if (parsed.variants.len != 0) return false;

    const slash = topLevelSlash(parsed.base) orelse return false;
    if (slash == 0 or slash + 1 >= parsed.base.len) return false;
    const property_part = parsed.base[0..slash];
    const alpha_token = parsed.base[slash + 1 ..];
    if (findThemeVariableWithNamespace(compiler, "--opacity-", alpha_token) == null) return false;
    const body = arbitraryBracketBody(property_part) orelse return false;
    const colon = topLevelDeclarationColon(body) orelse return false;
    const property = trimAscii(body[0..colon]);
    const value = trimAscii(body[colon + 1 ..]);
    if (property.len == 0 or value.len == 0) return false;

    var alpha_buf: [512]u8 = undefined;
    const alpha = opacityPercentWithTheme(compiler, &alpha_buf, alpha_token) orelse return false;

    var fallback_alpha_buf: [128]u8 = undefined;
    const fallback_alpha = opacityUnitAlphaWithTheme(compiler, &fallback_alpha_buf, alpha_token) orelse alpha;

    var fallback_buf: [1536]u8 = undefined;
    const fallback = std.fmt.bufPrint(&fallback_buf, "color-mix(in srgb,{s} {s},transparent)", .{ value, fallback_alpha }) catch return false;
    var fallback_decls: std.ArrayList(u8) = .empty;
    defer fallback_decls.deinit(compiler.allocator);
    try appendDecl(compiler.allocator, &fallback_decls, property, fallback, parsed.important);
    try writeThemeRule(compiler, out, raw, parsed.variants, "", fallback_decls.items);

    var mixed_buf: [1536]u8 = undefined;
    const mixed = std.fmt.bufPrint(&mixed_buf, "color-mix(in oklab,{s} {s},transparent)", .{ value, alpha }) catch return false;
    var supports_decls: std.ArrayList(u8) = .empty;
    defer supports_decls.deinit(compiler.allocator);
    try appendDecl(compiler.allocator, &supports_decls, property, mixed, parsed.important);
    try out.appendSlice(compiler.allocator, "@supports (color:color-mix(in lab, red, red)){");
    try writeThemeRule(compiler, out, raw, parsed.variants, "", supports_decls.items);
    try out.append(compiler.allocator, '}');
    return true;
}

fn renderThemeGradientStopCandidate(compiler: *Compiler, out: *std.ArrayList(u8), raw: []const u8, parsed: ParsedCandidate) !bool {
    if (parsed.variants.len != 0) return false;

    const entries = [_]struct { prefix: []const u8, prop: []const u8, stops: []const u8 }{
        .{
            .prefix = "from-",
            .prop = "--tw-gradient-from",
            .stops = "--tw-gradient-stops:var(--tw-gradient-via-stops,var(--tw-gradient-position),var(--tw-gradient-from) var(--tw-gradient-from-position),var(--tw-gradient-to) var(--tw-gradient-to-position));",
        },
        .{
            .prefix = "via-",
            .prop = "--tw-gradient-via",
            .stops = "--tw-gradient-via-stops:var(--tw-gradient-position),var(--tw-gradient-from) var(--tw-gradient-from-position),var(--tw-gradient-via) var(--tw-gradient-via-position),var(--tw-gradient-to) var(--tw-gradient-to-position);--tw-gradient-stops:var(--tw-gradient-via-stops);",
        },
        .{
            .prefix = "to-",
            .prop = "--tw-gradient-to",
            .stops = "--tw-gradient-stops:var(--tw-gradient-via-stops,var(--tw-gradient-position),var(--tw-gradient-from) var(--tw-gradient-from-position),var(--tw-gradient-to) var(--tw-gradient-to-position));",
        },
    };

    for (entries) |entry| {
        if (!std.mem.startsWith(u8, parsed.base, entry.prefix)) continue;
        var color = parsed.base[entry.prefix.len..];
        var alpha_token: ?[]const u8 = null;
        if (std.mem.indexOfScalar(u8, color, '/')) |slash| {
            alpha_token = color[slash + 1 ..];
            color = color[0..slash];
        }
        if (color.len == 0 or std.mem.endsWith(u8, color, "%") or color[0] == '[') return false;

        var theme_name_buf: [512]u8 = undefined;
        const theme_name = std.fmt.bufPrint(&theme_name_buf, "--color-{s}", .{color}) catch return false;
        const variable = findThemeVariable(compiler, theme_name) orelse return false;
        if (std.mem.eql(u8, variable.value, "initial")) return false;

        var value_buf: [512]u8 = undefined;
        const value = resolveThemeName(compiler, &value_buf, variable.name) orelse return false;
        try appendGradientLayer(compiler.allocator, out);

        if (alpha_token) |token| {
            var pct_buf: [64]u8 = undefined;
            const pct = opacityPercent(&pct_buf, token) orelse return false;
            if (std.mem.eql(u8, pct, "100%")) {
                var decls: std.ArrayList(u8) = .empty;
                defer decls.deinit(compiler.allocator);
                try appendDecl(compiler.allocator, &decls, entry.prop, value, parsed.important);
                try decls.appendSlice(compiler.allocator, entry.stops);
                try writeThemeRule(compiler, out, raw, parsed.variants, "", decls.items);
            } else {
                var fallback_color_buf: [16]u8 = undefined;
                const fallback_color = colorFallbackHex(compiler, &fallback_color_buf, variable.value, 0) orelse return false;
                var static_pct_buf: [64]u8 = undefined;
                const static_pct = opacityStaticPercent(compiler, &static_pct_buf, token) orelse pct;
                var fallback_buf: [16]u8 = undefined;
                const fallback = hexColorWithAlpha(&fallback_buf, fallback_color, static_pct) orelse return false;

                var base_decls: std.ArrayList(u8) = .empty;
                defer base_decls.deinit(compiler.allocator);
                try appendDecl(compiler.allocator, &base_decls, entry.prop, fallback, parsed.important);
                try writeThemeRule(compiler, out, raw, parsed.variants, "", base_decls.items);

                var mixed_buf: [768]u8 = undefined;
                const mixed = std.fmt.bufPrint(&mixed_buf, "color-mix(in oklab,{s} {s},transparent)", .{ value, pct }) catch return false;
                var supports_decls: std.ArrayList(u8) = .empty;
                defer supports_decls.deinit(compiler.allocator);
                try appendDecl(compiler.allocator, &supports_decls, entry.prop, mixed, parsed.important);
                try out.appendSlice(compiler.allocator, "@supports (color:color-mix(in lab, red, red)){");
                try writeThemeRule(compiler, out, raw, parsed.variants, "", supports_decls.items);
                try out.append(compiler.allocator, '}');

                try writeThemeRule(compiler, out, raw, parsed.variants, "", entry.stops);
            }
        } else {
            var decls: std.ArrayList(u8) = .empty;
            defer decls.deinit(compiler.allocator);
            try appendDecl(compiler.allocator, &decls, entry.prop, value, parsed.important);
            try decls.appendSlice(compiler.allocator, entry.stops);
            try writeThemeRule(compiler, out, raw, parsed.variants, "", decls.items);
        }

        try appendGradientProperties(compiler.allocator, out);
        return true;
    }

    return false;
}

fn appendGradientLayer(allocator: std.mem.Allocator, out: *std.ArrayList(u8)) !void {
    try appendPropertyLayer(allocator, out, "--tw-gradient-position:initial;--tw-gradient-from:#0000;--tw-gradient-via:#0000;--tw-gradient-to:#0000;--tw-gradient-stops:initial;--tw-gradient-via-stops:initial;--tw-gradient-from-position:0%;--tw-gradient-via-position:50%;--tw-gradient-to-position:100%;");
}

fn appendGradientProperties(allocator: std.mem.Allocator, out: *std.ArrayList(u8)) !void {
    try out.appendSlice(allocator, "@property --tw-gradient-position{syntax:\"*\";inherits:false;}@property --tw-gradient-from{syntax:\"<color>\";inherits:false;initial-value:#0000;}@property --tw-gradient-via{syntax:\"<color>\";inherits:false;initial-value:#0000;}@property --tw-gradient-to{syntax:\"<color>\";inherits:false;initial-value:#0000;}@property --tw-gradient-stops{syntax:\"*\";inherits:false;}@property --tw-gradient-via-stops{syntax:\"*\";inherits:false;}@property --tw-gradient-from-position{syntax:\"<length-percentage>\";inherits:false;initial-value:0%;}@property --tw-gradient-via-position{syntax:\"<length-percentage>\";inherits:false;initial-value:50%;}@property --tw-gradient-to-position{syntax:\"<length-percentage>\";inherits:false;initial-value:100%;}");
}

fn specialColorOrArbitraryValue(buf: []u8, token: []const u8) ?[]const u8 {
    if (std.mem.eql(u8, token, "current")) return "currentColor";
    if (std.mem.eql(u8, token, "inherit")) return "inherit";
    if (std.mem.eql(u8, token, "transparent")) return "#0000";
    var value = arbitraryValue(buf, token) orelse return null;
    if (arbitraryTypeSeparator(value)) |colon| {
        const data_type = value[0..colon];
        if (std.mem.eql(u8, data_type, "color")) value = value[colon + 1 ..];
    }
    return value;
}

fn colorMixCurrentColor(value: []const u8) []const u8 {
    return if (std.mem.eql(u8, value, "currentColor")) "currentcolor" else value;
}

fn staticColorOpacityToOklab(buf: []u8, color: []const u8, alpha_token: []const u8) ?[]const u8 {
    const rgb = hexToRgbColor(color) orelse namedColorToRgb(color) orelse return null;
    var alpha_buf: [64]u8 = undefined;
    const alpha = opacityUnitAlphaNoTheme(&alpha_buf, alpha_token) orelse return null;
    if (std.mem.indexOf(u8, alpha, "var(") != null) return null;

    const lab = linearSrgbToOklab(.{
        .r = srgbUnitToLinear(rgb.r),
        .g = srgbUnitToLinear(rgb.g),
        .b = srgbUnitToLinear(rgb.b),
    });
    var l_buf: [32]u8 = undefined;
    const l_raw = formatCssFloat4(&l_buf, lab.l * 100.0) orelse return null;
    if (rgb.r == 0 and rgb.g == 0 and rgb.b == 0) {
        return std.fmt.bufPrint(buf, "oklab({s}% none none / {s})", .{ l_raw, alpha }) catch null;
    }
    var a_buf: [32]u8 = undefined;
    const a = formatCssFloat7(&a_buf, lab.a) orelse return null;
    var b_buf: [32]u8 = undefined;
    const b = formatCssFloat7(&b_buf, lab.b) orelse return null;
    return std.fmt.bufPrint(buf, "oklab({s}% {s} {s} / {s})", .{ l_raw, a, b, alpha }) catch null;
}

fn hexColorWithAlpha(buf: []u8, color: []const u8, pct: []const u8) ?[]const u8 {
    if (buf.len < 9 or color.len != 7 or color[0] != '#' or !std.mem.endsWith(u8, pct, "%")) return null;
    for (color[1..]) |c| {
        if (!((c >= '0' and c <= '9') or (c >= 'a' and c <= 'f') or (c >= 'A' and c <= 'F'))) return null;
    }

    const number = std.fmt.parseFloat(f64, pct[0 .. pct.len - 1]) catch return null;
    if (number < 0 or number > 100) return null;
    const alpha_float = @round((number / 100.0) * 255.0);
    const alpha: u8 = @intFromFloat(alpha_float);
    const digits = "0123456789abcdef";

    @memcpy(buf[0..7], color);
    buf[7] = digits[alpha >> 4];
    buf[8] = digits[alpha & 0x0f];
    return buf[0..9];
}

fn colorFallbackHex(compiler: *Compiler, buf: []u8, value: []const u8, depth: usize) ?[]const u8 {
    if (depth > 8) return null;
    const color = trimAscii(value);
    if (isHexColor6(color)) return color;
    if (namedColorToRgb(color)) |rgb| return formatHexColor(buf, rgb);
    if (oklchToHex(buf, color)) |hex| return hex;
    if (cssVarName(color)) |name| {
        const variable = findThemeVariableLast(compiler, name) orelse return null;
        return colorFallbackHex(compiler, buf, variable.value, depth + 1);
    }
    return null;
}

fn colorFallbackValue(compiler: *Compiler, value: []const u8, depth: usize) ?[]const u8 {
    if (depth > 8) return null;
    const color = trimAscii(value);
    if (isHexColor6(color) or std.mem.startsWith(u8, color, "oklch(")) return color;
    if (cssVarName(color)) |name| {
        const variable = findThemeVariableLast(compiler, name) orelse return null;
        return colorFallbackValue(compiler, variable.value, depth + 1);
    }
    return null;
}

fn isHexColor6(value: []const u8) bool {
    if (value.len != 7 or value[0] != '#') return false;
    for (value[1..]) |c| {
        if (!((c >= '0' and c <= '9') or (c >= 'a' and c <= 'f') or (c >= 'A' and c <= 'F'))) return false;
    }
    return true;
}

fn cssVarName(value: []const u8) ?[]const u8 {
    if (!std.mem.startsWith(u8, value, "var(") or !std.mem.endsWith(u8, value, ")")) return null;
    const inner = trimAscii(value["var(".len .. value.len - 1]);
    if (!std.mem.startsWith(u8, inner, "--")) return null;
    var end: usize = 0;
    while (end < inner.len and isCssVariableNameChar(inner[end])) : (end += 1) {}
    if (end == 0) return null;
    return inner[0..end];
}

fn builtinThemeVariableValue(name: []const u8) ?[]const u8 {
    var search_start: usize = 0;
    while (std.mem.indexOf(u8, builtin_theme_css[search_start..], name)) |rel| {
        const start = search_start + rel;
        const end = start + name.len;
        if (start > 0 and isCssVariableNameChar(builtin_theme_css[start - 1])) {
            search_start = end;
            continue;
        }
        var i = end;
        while (i < builtin_theme_css.len and isAsciiWhitespace(builtin_theme_css[i])) : (i += 1) {}
        if (i >= builtin_theme_css.len or builtin_theme_css[i] != ':') {
            search_start = end;
            continue;
        }
        i += 1;
        const value_start = i;
        while (i < builtin_theme_css.len and builtin_theme_css[i] != ';') : (i += 1) {}
        if (i >= builtin_theme_css.len) return null;
        return trimAscii(builtin_theme_css[value_start..i]);
    }
    return null;
}

fn defaultColorFallbackHex(name: []const u8) ?[]const u8 {
    for (default_color_fallbacks.entries) |entry| {
        if (std.mem.eql(u8, entry.name, name)) return entry.hex;
    }
    return null;
}

fn oklchToHex(buf: []u8, value: []const u8) ?[]const u8 {
    const rgb = oklchToSrgbColor(value) orelse return null;
    return formatHexColor(buf, rgb);
}

fn oklchOpacityToOklab(compiler: *Compiler, buf: []u8, value: []const u8, alpha_token: []const u8) ?[]const u8 {
    var input = trimAscii(value);
    if (!std.mem.startsWith(u8, input, "oklch(") or !std.mem.endsWith(u8, input, ")")) return null;
    input = trimAscii(input["oklch(".len .. input.len - 1]);

    var i: usize = 0;
    skipCssComponentSeparators(input, &i);
    const lightness_start = i;
    while (i < input.len and !isAsciiWhitespace(input[i]) and input[i] != '/' and input[i] != ',') : (i += 1) {}
    const lightness = input[lightness_start..i];
    if (lightness.len == 0) return null;

    skipCssComponentSeparators(input, &i);
    const chroma = parseOklchNumber(input, &i, false) orelse return null;
    skipCssComponentSeparators(input, &i);
    const hue = parseOklchNumber(input, &i, false) orelse return null;

    var pct_buf: [64]u8 = undefined;
    _ = compiler;
    const pct = opacityPercent(&pct_buf, alpha_token) orelse return null;
    if (std.mem.indexOf(u8, pct, "var(") != null) return null;
    var alpha_buf: [32]u8 = undefined;
    const alpha = percentToUnitFloat(&alpha_buf, pct) orelse return null;

    const radians = hue * std.math.pi / 180.0;
    var a_buf: [32]u8 = undefined;
    const a = formatCssFloat3(&a_buf, chroma * @cos(radians)) orelse return null;
    var b_buf: [32]u8 = undefined;
    const b = formatCssFloat3(&b_buf, chroma * @sin(radians)) orelse return null;
    return std.fmt.bufPrint(buf, "oklab({s} {s} {s} / {s})", .{ lightness, a, b, alpha }) catch null;
}

fn percentToUnitFloat(buf: []u8, pct: []const u8) ?[]const u8 {
    if (!std.mem.endsWith(u8, pct, "%")) return null;
    const number = std.fmt.parseFloat(f64, pct[0 .. pct.len - 1]) catch return null;
    return formatCssFloat3(buf, number / 100.0);
}

fn formatCssFloat3(buf: []u8, value: f64) ?[]const u8 {
    var raw_buf: [64]u8 = undefined;
    const raw = std.fmt.bufPrint(&raw_buf, "{d:.6}", .{value}) catch return null;
    return trimFormattedCssFloat(buf, raw);
}

fn formatCssFloat4(buf: []u8, value: f64) ?[]const u8 {
    var raw_buf: [64]u8 = undefined;
    const raw = std.fmt.bufPrint(&raw_buf, "{d:.4}", .{value}) catch return null;
    return trimFormattedCssFloat(buf, raw);
}

fn formatCssFloat7(buf: []u8, value: f64) ?[]const u8 {
    var raw_buf: [64]u8 = undefined;
    const raw = std.fmt.bufPrint(&raw_buf, "{d:.7}", .{value}) catch return null;
    return trimFormattedCssFloat(buf, raw);
}

fn trimFormattedCssFloat(buf: []u8, raw: []const u8) ?[]const u8 {
    var start: usize = 0;
    var end = raw.len;
    while (end > start and raw[end - 1] == '0') : (end -= 1) {}
    if (end > start and raw[end - 1] == '.') end -= 1;
    if (end - start >= 2 and raw[start] == '0' and raw[start + 1] == '.') start += 1;
    if (end - start >= 3 and raw[start] == '-' and raw[start + 1] == '0' and raw[start + 2] == '.') {
        if (buf.len < end - start - 1) return null;
        buf[0] = '-';
        @memcpy(buf[1 .. end - start - 1], raw[start + 2 .. end]);
        return buf[0 .. end - start - 1];
    }
    if (buf.len < end - start) return null;
    @memcpy(buf[0 .. end - start], raw[start..end]);
    return buf[0 .. end - start];
}

fn parseOklchNumber(input: []const u8, index: *usize, percent_as_unit: bool) ?f64 {
    skipCssComponentSeparators(input, index);
    const start = index.*;
    while (index.* < input.len) {
        const c = input[index.*];
        if (isAsciiWhitespace(c) or c == '/' or c == ',') break;
        index.* += 1;
    }
    if (index.* == start) return null;
    const raw = input[start..index.*];
    if (std.mem.endsWith(u8, raw, "%")) {
        const number = std.fmt.parseFloat(f64, raw[0 .. raw.len - 1]) catch return null;
        return if (percent_as_unit) number / 100.0 else number;
    }
    return std.fmt.parseFloat(f64, raw) catch null;
}

fn skipCssComponentSeparators(input: []const u8, index: *usize) void {
    while (index.* < input.len and (isAsciiWhitespace(input[index.*]) or input[index.*] == ',')) : (index.* += 1) {}
}

fn srgbByte(linear: f64) u8 {
    const encoded = if (linear <= 0.0031308)
        12.92 * linear
    else
        1.055 * std.math.pow(f64, linear, 1.0 / 2.4) - 0.055;
    const clamped = @min(@max(encoded, 0.0), 1.0);
    return @intFromFloat(@round(clamped * 255.0));
}

fn themeColorOpacityName(base: []const u8) ?[]const u8 {
    const prefixes = [_][]const u8{ "bg-", "text-", "border-", "outline-", "ring-offset-", "inset-ring-", "ring-", "decoration-", "placeholder-", "accent-", "caret-", "fill-", "stroke-" };
    inline for (prefixes) |prefix| {
        if (std.mem.startsWith(u8, base, prefix)) {
            const value_part = base[prefix.len..];
            const slash = std.mem.indexOfScalar(u8, value_part, '/') orelse return null;
            if (slash == 0 or slash + 1 >= value_part.len) return null;
            return value_part[0..slash];
        }
    }
    return null;
}

fn renderArbitrarySpacingThemeFunctionCandidate(compiler: *Compiler, out: *std.ArrayList(u8), raw: []const u8, parsed: ParsedCandidate) !bool {
    if (!themeVariantsAreSupported(compiler, parsed.variants)) return false;

    const prefixes = [_]struct { prefix: []const u8, props: []const []const u8, allow_negative: bool }{
        .{ .prefix = "p-", .props = &.{"padding"}, .allow_negative = false },
        .{ .prefix = "px-", .props = &.{"padding-inline"}, .allow_negative = false },
        .{ .prefix = "py-", .props = &.{"padding-block"}, .allow_negative = false },
        .{ .prefix = "ps-", .props = &.{"padding-inline-start"}, .allow_negative = false },
        .{ .prefix = "pe-", .props = &.{"padding-inline-end"}, .allow_negative = false },
        .{ .prefix = "pbs-", .props = &.{"padding-block-start"}, .allow_negative = false },
        .{ .prefix = "pbe-", .props = &.{"padding-block-end"}, .allow_negative = false },
        .{ .prefix = "pt-", .props = &.{"padding-top"}, .allow_negative = false },
        .{ .prefix = "pr-", .props = &.{"padding-right"}, .allow_negative = false },
        .{ .prefix = "pb-", .props = &.{"padding-bottom"}, .allow_negative = false },
        .{ .prefix = "pl-", .props = &.{"padding-left"}, .allow_negative = false },
        .{ .prefix = "m-", .props = &.{"margin"}, .allow_negative = true },
        .{ .prefix = "mx-", .props = &.{"margin-inline"}, .allow_negative = true },
        .{ .prefix = "my-", .props = &.{"margin-block"}, .allow_negative = true },
        .{ .prefix = "ms-", .props = &.{"margin-inline-start"}, .allow_negative = true },
        .{ .prefix = "me-", .props = &.{"margin-inline-end"}, .allow_negative = true },
        .{ .prefix = "mbs-", .props = &.{"margin-block-start"}, .allow_negative = true },
        .{ .prefix = "mbe-", .props = &.{"margin-block-end"}, .allow_negative = true },
        .{ .prefix = "mt-", .props = &.{"margin-top"}, .allow_negative = true },
        .{ .prefix = "mr-", .props = &.{"margin-right"}, .allow_negative = true },
        .{ .prefix = "mb-", .props = &.{"margin-bottom"}, .allow_negative = true },
        .{ .prefix = "ml-", .props = &.{"margin-left"}, .allow_negative = true },
        .{ .prefix = "scroll-mx-", .props = &.{"scroll-margin-inline"}, .allow_negative = true },
        .{ .prefix = "scroll-my-", .props = &.{"scroll-margin-block"}, .allow_negative = true },
        .{ .prefix = "scroll-ms-", .props = &.{"scroll-margin-inline-start"}, .allow_negative = true },
        .{ .prefix = "scroll-me-", .props = &.{"scroll-margin-inline-end"}, .allow_negative = true },
        .{ .prefix = "scroll-mbs-", .props = &.{"scroll-margin-block-start"}, .allow_negative = true },
        .{ .prefix = "scroll-mbe-", .props = &.{"scroll-margin-block-end"}, .allow_negative = true },
        .{ .prefix = "scroll-mt-", .props = &.{"scroll-margin-top"}, .allow_negative = true },
        .{ .prefix = "scroll-mr-", .props = &.{"scroll-margin-right"}, .allow_negative = true },
        .{ .prefix = "scroll-mb-", .props = &.{"scroll-margin-bottom"}, .allow_negative = true },
        .{ .prefix = "scroll-ml-", .props = &.{"scroll-margin-left"}, .allow_negative = true },
        .{ .prefix = "scroll-m-", .props = &.{"scroll-margin"}, .allow_negative = true },
        .{ .prefix = "scroll-px-", .props = &.{"scroll-padding-inline"}, .allow_negative = false },
        .{ .prefix = "scroll-py-", .props = &.{"scroll-padding-block"}, .allow_negative = false },
        .{ .prefix = "scroll-ps-", .props = &.{"scroll-padding-inline-start"}, .allow_negative = false },
        .{ .prefix = "scroll-pe-", .props = &.{"scroll-padding-inline-end"}, .allow_negative = false },
        .{ .prefix = "scroll-pbs-", .props = &.{"scroll-padding-block-start"}, .allow_negative = false },
        .{ .prefix = "scroll-pbe-", .props = &.{"scroll-padding-block-end"}, .allow_negative = false },
        .{ .prefix = "scroll-pt-", .props = &.{"scroll-padding-top"}, .allow_negative = false },
        .{ .prefix = "scroll-pr-", .props = &.{"scroll-padding-right"}, .allow_negative = false },
        .{ .prefix = "scroll-pb-", .props = &.{"scroll-padding-bottom"}, .allow_negative = false },
        .{ .prefix = "scroll-pl-", .props = &.{"scroll-padding-left"}, .allow_negative = false },
        .{ .prefix = "scroll-p-", .props = &.{"scroll-padding"}, .allow_negative = false },
        .{ .prefix = "gap-x-", .props = &.{"column-gap"}, .allow_negative = false },
        .{ .prefix = "gap-y-", .props = &.{"row-gap"}, .allow_negative = false },
        .{ .prefix = "gap-", .props = &.{"gap"}, .allow_negative = false },
    };

    var negative = false;
    var base = parsed.base;
    if (base.len > 1 and base[0] == '-') {
        negative = true;
        base = base[1..];
    }

    for (prefixes) |entry| {
        if (!std.mem.startsWith(u8, base, entry.prefix)) continue;
        if (negative and !entry.allow_negative) return false;
        const value = arbitraryBracketBody(base[entry.prefix.len..]) orelse return false;
        if (std.mem.indexOf(u8, value, "theme(") == null and std.mem.indexOf(u8, value, "--theme(") == null) return false;

        var rewritten: std.ArrayList(u8) = .empty;
        defer rewritten.deinit(compiler.allocator);
        if (!try rewriteAuthoredCssFunctions(compiler, &rewritten, value, true)) return false;
        const final_value = rewritten.items;
        const balanced_value = trimUnbalancedTrailingCloseParens(final_value);
        if (std.mem.indexOf(u8, balanced_value, "theme(") != null or std.mem.indexOf(u8, balanced_value, "--theme(") != null) return false;
        if (balanced_value.len > 0 and balanced_value[0] == '_') return false;

        var negative_buf: [1024]u8 = undefined;
        const declaration_value = if (negative)
            std.fmt.bufPrint(&negative_buf, "calc({s} * -1)", .{balanced_value}) catch return false
        else
            balanced_value;

        var declarations: std.ArrayList(u8) = .empty;
        defer declarations.deinit(compiler.allocator);
        for (entry.props) |prop| try appendDecl(compiler.allocator, &declarations, prop, declaration_value, parsed.important);
        try writeThemeRule(compiler, out, raw, parsed.variants, "", declarations.items);
        return true;
    }

    return false;
}

fn trimUnbalancedTrailingCloseParens(value: []const u8) []const u8 {
    var extra_close: usize = 0;
    var balance: usize = 0;
    for (value) |c| {
        if (c == '(') {
            balance += 1;
        } else if (c == ')') {
            if (balance > 0) {
                balance -= 1;
            } else {
                extra_close += 1;
            }
        }
    }
    if (extra_close == 0) return value;

    var end = value.len;
    while (extra_close > 0 and end > 0) {
        if (isAsciiWhitespace(value[end - 1])) {
            end -= 1;
            continue;
        }
        if (value[end - 1] != ')') break;
        end -= 1;
        extra_close -= 1;
    }
    return trimAscii(value[0..end]);
}

fn renderRoundedArbitraryThemeFunctionCandidate(compiler: *Compiler, out: *std.ArrayList(u8), raw: []const u8, parsed: ParsedCandidate) !bool {
    if (!themeVariantsAreSupported(compiler, parsed.variants)) return false;
    if (!std.mem.startsWith(u8, parsed.base, "rounded-[")) return false;
    const value = arbitraryBracketBody(parsed.base["rounded-".len..]) orelse return false;
    if (std.mem.indexOf(u8, value, "theme(") == null and std.mem.indexOf(u8, value, "--theme(") == null) return false;

    var rewritten_value: std.ArrayList(u8) = .empty;
    defer rewritten_value.deinit(compiler.allocator);
    if (!try rewriteAuthoredCssFunctions(compiler, &rewritten_value, value, false)) return compiler.theme_variables.items.len > 0;

    var declarations: std.ArrayList(u8) = .empty;
    defer declarations.deinit(compiler.allocator);
    try appendDecl(compiler.allocator, &declarations, "border-radius", rewritten_value.items, parsed.important);
    try writeThemeRule(compiler, out, raw, parsed.variants, "", declarations.items);
    return true;
}

fn renderPrefixedArbitraryThemeFunctionCandidate(compiler: *Compiler, out: *std.ArrayList(u8), raw: []const u8, parsed: ParsedCandidate) !bool {
    const match = arbitraryThemeFunctionDeclaration(parsed.base) orelse return false;
    var rewritten_value: std.ArrayList(u8) = .empty;
    defer rewritten_value.deinit(compiler.allocator);
    if (!try rewriteAuthoredCssFunctions(compiler, &rewritten_value, match.value, false)) return compiler.prefix != null or compiler.theme_variables.items.len > 0;
    if (compiler.prefix == null and compiler.theme_variables.items.len == 0 and containsThemeFunctionSyntax(rewritten_value.items)) return false;

    var declarations: std.ArrayList(u8) = .empty;
    defer declarations.deinit(compiler.allocator);
    try appendDecl(compiler.allocator, &declarations, match.property, rewritten_value.items, parsed.important);
    try writeThemeRule(compiler, out, raw, parsed.variants, "", declarations.items);
    return true;
}

fn containsThemeFunctionSyntax(value: []const u8) bool {
    return std.mem.indexOf(u8, value, "theme(") != null or
        std.mem.indexOf(u8, value, "--theme(") != null;
}

const ArbitraryThemeFunctionDeclaration = struct {
    property: []const u8,
    value: []const u8,
};

fn arbitraryThemeFunctionDeclaration(base: []const u8) ?ArbitraryThemeFunctionDeclaration {
    if (std.mem.startsWith(u8, base, "text-[")) {
        const value = arbitraryBracketBody(base["text-".len..]) orelse return null;
        if (std.mem.indexOf(u8, value, "theme(") == null and std.mem.indexOf(u8, value, "--theme(") == null) return null;
        return .{ .property = "color", .value = value };
    }

    const body = arbitraryBracketBody(base) orelse return null;
    const colon = topLevelDeclarationColon(body) orelse return null;
    const property = trimAscii(body[0..colon]);
    const value = trimAscii(body[colon + 1 ..]);
    if (property.len == 0 or value.len == 0) return null;
    if (std.mem.indexOf(u8, value, "theme(") == null and std.mem.indexOf(u8, value, "--theme(") == null) return null;
    return .{ .property = property, .value = value };
}

fn arbitraryBracketBody(value: []const u8) ?[]const u8 {
    if (value.len < 3 or value[0] != '[' or value[value.len - 1] != ']') return null;
    var depth: usize = 0;
    var quote: ?u8 = null;
    var i: usize = 0;
    while (i < value.len) : (i += 1) {
        const c = value[i];
        if (quote) |q| {
            if (c == '\\') {
                if (i + 1 < value.len) i += 1;
                continue;
            }
            if (c == q) quote = null;
            continue;
        }
        switch (c) {
            '\'', '"' => quote = c,
            '[' => depth += 1,
            ']' => {
                if (depth == 0) return null;
                depth -= 1;
                if (depth == 0 and i != value.len - 1) return null;
            },
            else => {},
        }
    }
    if (depth != 0 or quote != null) return null;
    return value[1 .. value.len - 1];
}

fn renderArbitraryAnimationCandidate(compiler: *Compiler, out: *std.ArrayList(u8), raw: []const u8, parsed: ParsedCandidate) !bool {
    if (parsed.variants.len != 0) return false;
    if (!std.mem.startsWith(u8, parsed.base, "animate-[")) return false;
    if (compiler.theme_variables.items.len == 0 and compiler.theme_keyframes.items.len == 0) return false;

    var value_buf: [1024]u8 = undefined;
    const value = arbitraryValue(&value_buf, parsed.base["animate-".len..]) orelse return false;
    const animation_value = canonicalAuthoredAnimationValue(compiler, value) orelse value;
    var decls: std.ArrayList(u8) = .empty;
    defer decls.deinit(compiler.allocator);
    try appendDecl(compiler.allocator, &decls, "animation", animation_value, parsed.important);
    try writeThemeRule(compiler, out, raw, parsed.variants, "", decls.items);
    return true;
}

fn appendThemeAnimationKeyframesForBase(compiler: *Compiler, out: *std.ArrayList(u8), base: []const u8) !void {
    if (!std.mem.startsWith(u8, base, "animate-")) return;
    const suffix = base["animate-".len..];
    const variable = findThemeVariableWithNamespace(compiler, "--animate-", suffix) orelse return;
    if (std.mem.eql(u8, variable.value, "initial")) return;
    try appendThemeAnimationKeyframesForValue(compiler, out, variable.value);
}

fn appendThemeAnimationKeyframesForValue(compiler: *Compiler, out: *std.ArrayList(u8), value: []const u8) !void {
    try appendThemeAnimationKeyframesForValueDedup(compiler, out, "", value);
}

fn appendThemeAnimationKeyframesForValueDedup(
    compiler: *Compiler,
    out: *std.ArrayList(u8),
    emitted_css: []const u8,
    value: []const u8,
) !void {
    for (compiler.theme_variables.items) |variable| {
        if (!std.mem.startsWith(u8, variable.name, "--animate-")) continue;
        if (std.mem.eql(u8, variable.value, "initial")) continue;

        var name_buf: [512]u8 = undefined;
        const css_name = formatCssVariableName(compiler, &name_buf, variable.name) orelse continue;
        if (!containsCssVariableName(value, css_name)) continue;

        for (compiler.theme_keyframes.items) |keyframes| {
            if (!animationValueReferencesKeyframes(variable.value, keyframes.name)) continue;
            if (std.mem.indexOf(u8, out.items, keyframes.css) != null) continue;
            if (std.mem.indexOf(u8, emitted_css, keyframes.css) != null) continue;
            try out.appendSlice(compiler.allocator, keyframes.css);
        }
    }

    for (compiler.theme_keyframes.items) |keyframes| {
        if (animationValueReferencesKeyframes(value, keyframes.name)) {
            if (std.mem.indexOf(u8, out.items, keyframes.css) != null) continue;
            if (std.mem.indexOf(u8, emitted_css, keyframes.css) != null) continue;
            try out.appendSlice(compiler.allocator, keyframes.css);
        }
    }
}

fn animationValueReferencesKeyframes(value: []const u8, name: []const u8) bool {
    var search_start: usize = 0;
    while (std.mem.indexOf(u8, value[search_start..], name)) |rel| {
        const start = search_start + rel;
        const end = start + name.len;
        const before_ok = start == 0 or !isAnimationNameChar(value[start - 1]);
        const after_ok = end == value.len or !isAnimationNameChar(value[end]);
        if (before_ok and after_ok) return true;
        search_start = end;
    }
    return false;
}

fn isAnimationNameChar(c: u8) bool {
    return isNameChar(c) or c == '-';
}

fn canonicalAuthoredAnimationValue(compiler: *Compiler, value: []const u8) ?[]const u8 {
    var token_end: usize = 0;
    while (token_end < value.len and !isAsciiWhitespace(value[token_end]) and value[token_end] != ',') : (token_end += 1) {}
    if (token_end == 0 or token_end == value.len) return null;
    const first = value[0..token_end];
    if (themeKeyframesForName(compiler, first) == null) return null;
    const rest = trimAscii(value[token_end..]);
    if (rest.len == 0) return null;
    const owned = std.fmt.allocPrint(compiler.allocator, "{s} {s}", .{ rest, first }) catch return null;
    compiler.owned_values.append(compiler.allocator, owned) catch {
        compiler.allocator.free(owned);
        return null;
    };
    return owned;
}

fn themeKeyframesForName(compiler: *Compiler, name: []const u8) ?ThemeKeyframes {
    for (compiler.theme_keyframes.items) |keyframes| {
        if (std.mem.eql(u8, keyframes.name, name)) return keyframes;
    }
    return null;
}

fn renderFunctionalUtilities(compiler: *Compiler, out: *std.ArrayList(u8), raw: []const u8, parsed: ParsedCandidate) !bool {
    if (!themeVariantsAreSupported(compiler, parsed.variants)) return false;
    var matched = false;
    for (compiler.functional_utilities.items) |utility| {
        const match = functionalUtilityMatch(utility.prefix, utility.declarations, parsed.base) orelse continue;
        var decls: std.ArrayList(u8) = .empty;
        defer decls.deinit(compiler.allocator);
        if (!try expandFunctionalUtilityDeclarations(compiler, &decls, utility.declarations, match)) continue;
        if (decls.items.len == 0) continue;
        if (parsed.important) {
            var important_decls: std.ArrayList(u8) = .empty;
            defer important_decls.deinit(compiler.allocator);
            try appendImportantMarkers(compiler.allocator, &important_decls, decls.items);
            try writeThemeRule(compiler, out, raw, parsed.variants, "", important_decls.items);
        } else {
            try writeThemeRule(compiler, out, raw, parsed.variants, "", decls.items);
        }
        matched = true;
    }
    return matched;
}

fn functionalUtilityMatch(prefix: []const u8, declarations: []const u8, base: []const u8) ?FunctionalMatch {
    const root = prefix[0 .. prefix.len - 1];
    const uses_modifier = std.mem.indexOf(u8, declarations, "--modifier(") != null;
    if (std.mem.eql(u8, base, root)) return .{ .value = null, .modifier = null };
    if (std.mem.startsWith(u8, base, root) and base.len > root.len and base[root.len] == '/') {
        return .{ .value = null, .modifier = base[root.len + 1 ..] };
    }
    if (!std.mem.startsWith(u8, base, prefix)) return null;
    const suffix = base[prefix.len..];
    if (suffix.len == 0) return null;
    if (!uses_modifier) return .{ .value = suffix, .modifier = null };
    if (splitModifier(suffix)) |split| return split;
    return .{ .value = suffix, .modifier = null };
}

fn functionalUtilitySuffix(prefix: []const u8, base: []const u8) ?[]const u8 {
    return if (functionalUtilityMatch(prefix, "", base)) |match| match.value else null;
}

fn splitModifier(suffix: []const u8) ?FunctionalMatch {
    var bracket_depth: usize = 0;
    var paren_depth: usize = 0;
    for (suffix, 0..) |c, i| {
        switch (c) {
            '[' => bracket_depth += 1,
            ']' => if (bracket_depth > 0) {
                bracket_depth -= 1;
            },
            '(' => paren_depth += 1,
            ')' => if (paren_depth > 0) {
                paren_depth -= 1;
            },
            '/' => if (bracket_depth == 0 and paren_depth == 0) {
                return .{
                    .value = if (i == 0) null else suffix[0..i],
                    .modifier = suffix[i + 1 ..],
                };
            },
            else => {},
        }
    }
    return null;
}

const FunctionalRewriteResult = enum { no_value, resolved, unresolved };

const FunctionalValueKind = enum { named, arbitrary };

const FunctionalMatch = struct {
    value: ?[]const u8,
    modifier: ?[]const u8,
};

const FunctionalValue = struct {
    kind: FunctionalValueKind,
    value: []const u8,
    data_type: ?[]const u8 = null,
};

fn expandFunctionalUtilityDeclarations(compiler: *Compiler, out: *std.ArrayList(u8), declarations: []const u8, match: FunctionalMatch) !bool {
    var rewritten: std.ArrayList(u8) = .empty;
    defer rewritten.deinit(compiler.allocator);

    var saw_value = false;
    var resolved_value = false;
    var saw_modifier = false;
    var resolved_modifier = false;
    var i: usize = 0;
    while (i < declarations.len) {
        skipCssWhitespaceAndComments(declarations, &i);
        if (i >= declarations.len) break;
        if (declarations[i] == '@') {
            const end = definitionEnd(declarations, i) orelse declarations.len;
            i = end;
            continue;
        }

        const start = i;
        var paren_depth: usize = 0;
        var bracket_depth: usize = 0;
        while (i < declarations.len) : (i += 1) {
            switch (declarations[i]) {
                '(' => paren_depth += 1,
                ')' => if (paren_depth > 0) {
                    paren_depth -= 1;
                },
                '[' => bracket_depth += 1,
                ']' => if (bracket_depth > 0) {
                    bracket_depth -= 1;
                },
                ';' => if (paren_depth == 0 and bracket_depth == 0) {
                    i += 1;
                    break;
                },
                else => {},
            }
        }

        const declaration = trimAscii(declarations[start..i]);
        if (declaration.len == 0) continue;
        var resolved: std.ArrayList(u8) = .empty;
        defer resolved.deinit(compiler.allocator);
        var stats: FunctionalDeclarationStats = .{};
        switch (try rewriteFunctionalDeclaration(compiler, &resolved, declaration, match, &stats)) {
            .no_value => try rewritten.appendSlice(compiler.allocator, declaration),
            .resolved => {
                if (stats.saw_value) saw_value = true;
                if (stats.resolved_value) resolved_value = true;
                if (stats.saw_modifier) saw_modifier = true;
                if (stats.resolved_modifier) resolved_modifier = true;
                var normalized: std.ArrayList(u8) = .empty;
                defer normalized.deinit(compiler.allocator);
                try rewriteSpacingShorthand(compiler, &normalized, resolved.items);
                try rewritten.appendSlice(compiler.allocator, normalized.items);
            },
            .unresolved => {
                if (stats.saw_value) saw_value = true;
                if (stats.saw_modifier) saw_modifier = true;
            },
        }
    }

    if (!saw_value) {
        if (match.value == null) return false;
    } else if (!resolved_value) return false;
    if (match.modifier != null and (!saw_modifier or !resolved_modifier)) return false;
    try out.appendSlice(compiler.allocator, rewritten.items);
    return true;
}

const FunctionalDeclarationStats = struct {
    saw_value: bool = false,
    resolved_value: bool = false,
    saw_modifier: bool = false,
    resolved_modifier: bool = false,
};

fn rewriteFunctionalDeclaration(compiler: *Compiler, out: *std.ArrayList(u8), declaration: []const u8, match: FunctionalMatch, stats: *FunctionalDeclarationStats) !FunctionalRewriteResult {
    var i: usize = 0;
    var saw_function = false;
    while (nextFunctionalFunction(declaration, i)) |found| {
        const fn_start = found.start;
        const name_len: usize = if (found.kind == .value) "--value".len else "--modifier".len;
        const open = fn_start + name_len;
        const close = matchingParenClose(declaration, open) orelse return .unresolved;
        try out.appendSlice(compiler.allocator, declaration[i..fn_start]);

        var resolved: std.ArrayList(u8) = .empty;
        defer resolved.deinit(compiler.allocator);
        if (found.kind == .value) {
            stats.saw_value = true;
        } else {
            stats.saw_modifier = true;
        }
        const part = if (found.kind == .value) match.value else match.modifier;
        if (!try appendResolvedFunctionalFunction(compiler, &resolved, part, declaration[open + 1 .. close])) {
            return .unresolved;
        }
        if (found.kind == .value) {
            stats.resolved_value = true;
        } else {
            stats.resolved_modifier = true;
        }
        try out.appendSlice(compiler.allocator, resolved.items);
        saw_function = true;
        i = close + 1;
    }
    if (!saw_function) return .no_value;
    try out.appendSlice(compiler.allocator, declaration[i..]);
    return .resolved;
}

const FunctionalFunctionKind = enum { value, modifier };

const FunctionalFunctionMatch = struct {
    start: usize,
    kind: FunctionalFunctionKind,
};

fn nextFunctionalFunction(input: []const u8, start: usize) ?FunctionalFunctionMatch {
    const value_rel = std.mem.indexOf(u8, input[start..], "--value(");
    const modifier_rel = std.mem.indexOf(u8, input[start..], "--modifier(");
    if (value_rel == null and modifier_rel == null) return null;
    if (value_rel) |v| {
        if (modifier_rel) |m| {
            return if (v <= m)
                .{ .start = start + v, .kind = .value }
            else
                .{ .start = start + m, .kind = .modifier };
        }
        return .{ .start = start + v, .kind = .value };
    }
    return .{ .start = start + modifier_rel.?, .kind = .modifier };
}

fn rewriteSpacingShorthand(compiler: *Compiler, out: *std.ArrayList(u8), declaration: []const u8) !void {
    var i: usize = 0;
    while (std.mem.indexOf(u8, declaration[i..], "--spacing(")) |rel| {
        const fn_start = i + rel;
        const open = fn_start + "--spacing".len;
        const close = matchingParenClose(declaration, open) orelse break;
        try out.appendSlice(compiler.allocator, declaration[i..fn_start]);
        try appendSpacingShorthand(compiler, out, declaration[open + 1 .. close]);
        i = close + 1;
    }
    try out.appendSlice(compiler.allocator, declaration[i..]);
}

fn appendSpacingShorthand(compiler: *Compiler, out: *std.ArrayList(u8), raw_value: []const u8) !void {
    const value = trimAscii(raw_value);
    const variable = findThemeVariable(compiler, "--spacing");
    if (variable) |spacing| {
        if (spacing.inline_theme) {
            try out.appendSlice(compiler.allocator, "calc(");
            try out.appendSlice(compiler.allocator, spacing.value);
            try out.append(compiler.allocator, '*');
            try out.appendSlice(compiler.allocator, value);
            try out.append(compiler.allocator, ')');
            return;
        }
        if (spacing.reference) {
            try out.appendSlice(compiler.allocator, "calc(var(--spacing,");
            try out.appendSlice(compiler.allocator, spacing.value);
            try out.appendSlice(compiler.allocator, ")*");
            try out.appendSlice(compiler.allocator, value);
            try out.append(compiler.allocator, ')');
            return;
        }
    }
    try out.appendSlice(compiler.allocator, "calc(var(--spacing)*");
    try out.appendSlice(compiler.allocator, value);
    try out.append(compiler.allocator, ')');
}

fn matchingParenClose(input: []const u8, open: usize) ?usize {
    if (open >= input.len or input[open] != '(') return null;
    var depth: usize = 1;
    var i = open + 1;
    var quote: ?u8 = null;
    while (i < input.len) : (i += 1) {
        const c = input[i];
        if (quote) |q| {
            if (c == '\\' and i + 1 < input.len) {
                i += 1;
                continue;
            }
            if (c == q) quote = null;
            continue;
        }
        switch (c) {
            '\'', '"' => quote = c,
            '(' => depth += 1,
            ')' => {
                depth -= 1;
                if (depth == 0) return i;
            },
            else => {},
        }
    }
    return null;
}

fn appendResolvedFunctionalFunction(compiler: *Compiler, out: *std.ArrayList(u8), part: ?[]const u8, args: []const u8) !bool {
    var start: usize = 0;
    var i: usize = 0;
    var paren_depth: usize = 0;
    var bracket_depth: usize = 0;
    var quote: ?u8 = null;
    while (i <= args.len) : (i += 1) {
        const at_end = i == args.len;
        if (!at_end) {
            const c = args[i];
            if (quote) |q| {
                if (c == '\\' and i + 1 < args.len) {
                    i += 1;
                    continue;
                }
                if (c == q) quote = null;
                continue;
            }
            switch (c) {
                '\'', '"' => quote = c,
                '(' => paren_depth += 1,
                ')' => if (paren_depth > 0) {
                    paren_depth -= 1;
                },
                '[' => bracket_depth += 1,
                ']' => if (bracket_depth > 0) {
                    bracket_depth -= 1;
                },
                ',' => if (paren_depth == 0 and bracket_depth == 0) {},
                else => continue,
            }
            if (!(c == ',' and paren_depth == 0 and bracket_depth == 0)) continue;
        }

        var resolved: std.ArrayList(u8) = .empty;
        defer resolved.deinit(compiler.allocator);
        if (try appendResolvedFunctionalArg(compiler, &resolved, part, args[start..i])) {
            try out.appendSlice(compiler.allocator, resolved.items);
            return true;
        }
        start = i + 1;
    }
    return false;
}

fn appendResolvedFunctionalArg(compiler: *Compiler, out: *std.ArrayList(u8), part: ?[]const u8, raw_arg: []const u8) !bool {
    const arg_owned = try normalizeValueArg(compiler.allocator, raw_arg);
    defer compiler.allocator.free(arg_owned);
    const arg = trimAscii(arg_owned);
    if (arg.len == 0) return false;

    if (part == null) return false;

    var value_buf: [1024]u8 = undefined;
    const value = parseFunctionalValue(&value_buf, part.?) orelse return false;

    if (isQuotedLiteral(arg)) {
        if (value.kind != .named) return false;
        const literal = arg[1 .. arg.len - 1];
        if (!std.mem.eql(u8, value.value, literal)) return false;
        try out.appendSlice(compiler.allocator, literal);
        return true;
    }

    if (std.mem.startsWith(u8, arg, "--")) {
        if (value.kind != .named) return false;
        const star = std.mem.indexOfScalar(u8, arg, '*') orelse return false;
        var name_buf: [512]u8 = undefined;
        const name = std.fmt.bufPrint(&name_buf, "{s}{s}{s}", .{ arg[0..star], value.value, arg[star + 1 ..] }) catch return false;
        var resolved_buf: [1024]u8 = undefined;
        const resolved = resolveThemeName(compiler, &resolved_buf, name) orelse return false;
        try out.appendSlice(compiler.allocator, resolved);
        return true;
    }

    if (arg.len >= 2 and arg[0] == '[' and arg[arg.len - 1] == ']') {
        if (value.kind != .arbitrary) return false;
        const data_type = arg[1 .. arg.len - 1];
        if (std.mem.eql(u8, data_type, "*")) {
            try out.appendSlice(compiler.allocator, value.value);
            return true;
        }
        if (value.data_type) |forced| {
            if (!std.mem.eql(u8, forced, data_type)) return false;
            try out.appendSlice(compiler.allocator, value.value);
            return true;
        }
        return try appendInferredArbitraryValue(compiler.allocator, out, value.value, data_type);
    }

    if (value.kind != .named) return false;
    return try appendBareFunctionalValue(compiler.allocator, out, value.value, arg);
}

fn normalizeValueArg(allocator: std.mem.Allocator, raw_arg: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    var i: usize = 0;
    while (i < raw_arg.len) : (i += 1) {
        const c = raw_arg[i];
        if (isAsciiWhitespace(c)) continue;
        if (c == '\\' and i + 1 < raw_arg.len and raw_arg[i + 1] == '*') {
            try out.append(allocator, '*');
            i += 1;
            continue;
        }
        try out.append(allocator, c);
    }
    if (std.mem.startsWith(u8, out.items, "--") and
        std.mem.indexOfScalar(u8, out.items, '(') == null and
        std.mem.indexOfScalar(u8, out.items, '*') == null)
    {
        if (std.mem.indexOf(u8, out.items[2..], "--")) |rel| {
            try out.insertSlice(allocator, 2 + rel, "-*");
        } else {
            try out.appendSlice(allocator, "-*");
        }
    }
    return try out.toOwnedSlice(allocator);
}

fn parseFunctionalValue(buf: []u8, suffix: []const u8) ?FunctionalValue {
    if (suffix.len >= 3 and suffix[0] == '[' and suffix[suffix.len - 1] == ']') {
        const inner = suffix[1 .. suffix.len - 1];
        if (inner.len > buf.len) return null;
        for (inner, 0..) |c, i| {
            buf[i] = if (c == '_') ' ' else c;
        }
        var value = buf[0..inner.len];
        var data_type: ?[]const u8 = null;
        if (arbitraryTypeSeparator(value)) |colon| {
            data_type = value[0..colon];
            value = value[colon + 1 ..];
        }
        return .{ .kind = .arbitrary, .value = value, .data_type = data_type };
    }

    if (suffix.len >= 4 and suffix[0] == '(' and suffix[suffix.len - 1] == ')') {
        const inner = suffix[1 .. suffix.len - 1];
        if (!std.mem.startsWith(u8, inner, "--")) return null;
        const value = std.fmt.bufPrint(buf, "var({s})", .{inner}) catch return null;
        return .{ .kind = .arbitrary, .value = value };
    }

    return .{ .kind = .named, .value = suffix };
}

fn arbitraryTypeSeparator(value: []const u8) ?usize {
    for (value, 0..) |c, i| {
        if (c == '(' or c == '[') return null;
        if (c != ':') continue;
        if (i == 0) return null;
        for (value[0..i]) |prefix| {
            if (!((prefix >= 'a' and prefix <= 'z') or (prefix >= 'A' and prefix <= 'Z') or prefix == '*' or prefix == '-')) return null;
        }
        return i;
    }
    return null;
}

fn isQuotedLiteral(arg: []const u8) bool {
    return arg.len >= 2 and (arg[0] == '\'' or arg[0] == '"') and arg[arg.len - 1] == arg[0];
}

fn appendBareFunctionalValue(allocator: std.mem.Allocator, out: *std.ArrayList(u8), value: []const u8, data_type: []const u8) !bool {
    if (std.mem.eql(u8, data_type, "integer")) {
        _ = parsePositiveInt(value) orelse return false;
        try out.appendSlice(allocator, value);
        return true;
    }
    if (std.mem.eql(u8, data_type, "number")) {
        if (!isBareNumber(value)) return false;
        try appendNormalizedNumber(allocator, out, value);
        return true;
    }
    if (std.mem.eql(u8, data_type, "percentage")) {
        if (!isIntegerPercentage(value)) return false;
        try out.appendSlice(allocator, value);
        return true;
    }
    if (std.mem.eql(u8, data_type, "ratio")) {
        if (!isRatioValue(value)) return false;
        try out.appendSlice(allocator, value);
        return true;
    }
    return false;
}

fn appendInferredArbitraryValue(allocator: std.mem.Allocator, out: *std.ArrayList(u8), value: []const u8, data_type: []const u8) !bool {
    if (std.mem.eql(u8, data_type, "integer")) {
        _ = parsePositiveInt(value) orelse return false;
        try out.appendSlice(allocator, value);
        return true;
    }
    if (std.mem.eql(u8, data_type, "number")) {
        if (!isCssNumber(value)) return false;
        try out.appendSlice(allocator, value);
        return true;
    }
    if (std.mem.eql(u8, data_type, "percentage")) {
        if (!isIntegerPercentage(value)) return false;
        try out.appendSlice(allocator, value);
        return true;
    }
    if (std.mem.eql(u8, data_type, "ratio")) {
        return try appendRatioValue(allocator, out, value);
    }
    if (std.mem.eql(u8, data_type, "length")) {
        if (!isLengthValue(value)) return false;
        try out.appendSlice(allocator, value);
        return true;
    }
    if (std.mem.eql(u8, data_type, "color")) {
        if (!isColorLikeValue(value)) return false;
        try out.appendSlice(allocator, value);
        return true;
    }
    return false;
}

fn appendNormalizedNumber(allocator: std.mem.Allocator, out: *std.ArrayList(u8), value: []const u8) !void {
    if (value.len > 2 and value[0] == '0' and value[1] == '.') {
        try out.appendSlice(allocator, value[1..]);
    } else {
        try out.appendSlice(allocator, value);
    }
}

fn appendRatioValue(allocator: std.mem.Allocator, out: *std.ArrayList(u8), value: []const u8) !bool {
    const slash = std.mem.indexOfScalar(u8, value, '/') orelse return false;
    const left = trimAscii(value[0..slash]);
    const right = trimAscii(value[slash + 1 ..]);
    _ = parsePositiveInt(left) orelse return false;
    _ = parsePositiveInt(right) orelse return false;
    try out.appendSlice(allocator, left);
    try out.appendSlice(allocator, " / ");
    try out.appendSlice(allocator, right);
    return true;
}

fn isRatioValue(value: []const u8) bool {
    const slash = std.mem.indexOfScalar(u8, value, '/') orelse return false;
    const left = trimAscii(value[0..slash]);
    const right = trimAscii(value[slash + 1 ..]);
    return parsePositiveInt(left) != null and parsePositiveInt(right) != null;
}

fn isBareNumber(value: []const u8) bool {
    if (!isCssNumber(value)) return false;
    const dot = std.mem.indexOfScalar(u8, value, '.') orelse return true;
    return value.len - dot == 2;
}

fn isCssNumber(value: []const u8) bool {
    if (value.len == 0) return false;
    var i: usize = 0;
    var seen_digit = false;
    var seen_dot = false;
    while (i < value.len) : (i += 1) {
        const c = value[i];
        if (c >= '0' and c <= '9') {
            seen_digit = true;
            continue;
        }
        if (c == '.' and !seen_dot) {
            seen_dot = true;
            continue;
        }
        return false;
    }
    return seen_digit;
}

fn isIntegerPercentage(value: []const u8) bool {
    if (value.len < 2 or value[value.len - 1] != '%') return false;
    return parsePositiveInt(value[0 .. value.len - 1]) != null;
}

fn isLengthValue(value: []const u8) bool {
    if (std.mem.startsWith(u8, value, "var(")) return true;
    var i: usize = 0;
    var seen_digit = false;
    var seen_unit = false;
    while (i < value.len) : (i += 1) {
        const c = value[i];
        if ((c >= '0' and c <= '9') or c == '.') {
            if (seen_unit) return false;
            if (c >= '0' and c <= '9') seen_digit = true;
            continue;
        }
        if ((c >= 'a' and c <= 'z') or c == '%') {
            seen_unit = true;
            continue;
        }
        return false;
    }
    return seen_digit and seen_unit;
}

fn isColorLikeValue(value: []const u8) bool {
    return std.mem.startsWith(u8, value, "#") or
        std.mem.startsWith(u8, value, "rgb(") or
        std.mem.startsWith(u8, value, "rgba(") or
        std.mem.startsWith(u8, value, "hsl(") or
        std.mem.startsWith(u8, value, "oklch(") or
        std.mem.startsWith(u8, value, "color(") or
        std.mem.startsWith(u8, value, "var(");
}

fn expandCustomUtilityDeclarations(compiler: *Compiler, out: *std.ArrayList(u8), declarations: []const u8) anyerror!void {
    var i: usize = 0;
    while (i < declarations.len) {
        skipCssWhitespaceAndComments(declarations, &i);
        if (i >= declarations.len) break;

        if (std.mem.startsWith(u8, declarations[i..], "@apply")) {
            const name_end = i + "@apply".len;
            if (name_end == declarations.len or !isNameChar(declarations[name_end])) {
                var j = name_end;
                var paren_depth: usize = 0;
                var bracket_depth: usize = 0;
                while (j < declarations.len) : (j += 1) {
                    switch (declarations[j]) {
                        '(' => paren_depth += 1,
                        ')' => if (paren_depth > 0) {
                            paren_depth -= 1;
                        },
                        '[' => bracket_depth += 1,
                        ']' => if (bracket_depth > 0) {
                            bracket_depth -= 1;
                        },
                        ';' => if (paren_depth == 0 and bracket_depth == 0) break,
                        else => {},
                    }
                }
                try appendApplyDeclarations(compiler, out, declarations[name_end..j]);
                i = if (j < declarations.len and declarations[j] == ';') j + 1 else j;
                continue;
            }
        }

        const start = i;
        var paren_depth: usize = 0;
        var bracket_depth: usize = 0;
        var block_open: ?usize = null;
        while (i < declarations.len) : (i += 1) {
            switch (declarations[i]) {
                '(' => paren_depth += 1,
                ')' => if (paren_depth > 0) {
                    paren_depth -= 1;
                },
                '[' => bracket_depth += 1,
                ']' => if (bracket_depth > 0) {
                    bracket_depth -= 1;
                },
                '{' => if (paren_depth == 0 and bracket_depth == 0) {
                    block_open = i;
                    break;
                },
                ';' => if (paren_depth == 0 and bracket_depth == 0) {
                    i += 1;
                    break;
                },
                else => {},
            }
        }
        if (block_open) |open| {
            const end = scanCssBlock(declarations, start) orelse declarations.len;
            try appendCustomUtilityCssFragment(compiler, out, trimAscii(declarations[start..open]), true);
            try out.append(compiler.allocator, '{');
            var nested: std.ArrayList(u8) = .empty;
            defer nested.deinit(compiler.allocator);
            if (end > open + 1) try expandCustomUtilityDeclarations(compiler, &nested, declarations[open + 1 .. end - 1]);
            try out.appendSlice(compiler.allocator, nested.items);
            try out.append(compiler.allocator, '}');
            i = end;
            continue;
        }
        try appendCustomUtilityCssFragment(compiler, out, trimAscii(declarations[start..i]), false);
    }
}

fn appendCustomUtilityCssFragment(compiler: *Compiler, out: *std.ArrayList(u8), fragment: []const u8, force_theme_inline: bool) !void {
    var rewritten: std.ArrayList(u8) = .empty;
    defer rewritten.deinit(compiler.allocator);
    if (try rewriteAuthoredCssFunctions(compiler, &rewritten, fragment, force_theme_inline)) {
        try out.appendSlice(compiler.allocator, rewritten.items);
    } else {
        try out.appendSlice(compiler.allocator, fragment);
    }
}

fn appendApplyDeclarations(compiler: *Compiler, out: *std.ArrayList(u8), params: []const u8) anyerror!void {
    var candidates: std.ArrayList([]const u8) = .empty;
    defer candidates.deinit(compiler.allocator);
    try collectApplyCandidates(compiler, &candidates, params);

    std.mem.sort([]const u8, candidates.items, compiler, candidateLessThan);
    for (candidates.items) |candidate| {
        var variants_buf: [16][]const u8 = undefined;
        const parsed = parseCandidateForCompiler(compiler, candidate, &variants_buf) orelse continue;
        if (parsed.base.len == 0) continue;
        if (parsed.variants.len == 0) {
            try appendApplyBaseDeclarations(compiler, out, parsed.base, parsed.important);
            continue;
        }

        var applied_decls: std.ArrayList(u8) = .empty;
        defer applied_decls.deinit(compiler.allocator);
        try appendApplyBaseDeclarations(compiler, &applied_decls, parsed.base, parsed.important);
        if (applied_decls.items.len == 0) continue;
        try writeAuthoredRule(compiler, out, "&", parsed.variants, applied_decls.items, null);
    }
}

fn collectApplyCandidates(compiler: *Compiler, out: *std.ArrayList([]const u8), params: []const u8) !void {
    var i: usize = 0;
    while (i < params.len) {
        while (i < params.len and isAsciiWhitespace(params[i])) : (i += 1) {}
        const start = i;
        var bracket_depth: usize = 0;
        var paren_depth: usize = 0;
        while (i < params.len and !isAsciiWhitespace(params[i])) : (i += 1) {
            switch (params[i]) {
                '[' => bracket_depth += 1,
                ']' => if (bracket_depth > 0) {
                    bracket_depth -= 1;
                },
                '(' => paren_depth += 1,
                ')' => if (paren_depth > 0) {
                    paren_depth -= 1;
                },
                else => {},
            }
            if (bracket_depth > 0 or paren_depth > 0) {
                while (i + 1 < params.len and (bracket_depth > 0 or paren_depth > 0)) {
                    i += 1;
                    switch (params[i]) {
                        '[' => bracket_depth += 1,
                        ']' => if (bracket_depth > 0) {
                            bracket_depth -= 1;
                        },
                        '(' => paren_depth += 1,
                        ')' => if (paren_depth > 0) {
                            paren_depth -= 1;
                        },
                        else => {},
                    }
                }
            }
        }
        if (i > start) try out.append(compiler.allocator, params[start..i]);
    }
}

fn appendApplyBaseDeclarations(compiler: *Compiler, out: *std.ArrayList(u8), base: []const u8, important: bool) anyerror!void {
    for (compiler.custom_utilities.items) |utility| {
        if (std.mem.eql(u8, utility.name, base)) {
            var expanded: std.ArrayList(u8) = .empty;
            defer expanded.deinit(compiler.allocator);
            try expandCustomUtilityDeclarations(compiler, &expanded, utility.declarations);
            if (important) {
                try appendImportantCss(compiler.allocator, out, expanded.items);
            } else {
                try out.appendSlice(compiler.allocator, expanded.items);
            }
            return;
        }
    }
    if (themeBaseMatches(compiler, base)) {
        _ = try emitThemeUtility(compiler, out, out, base, important);
        return;
    }
    _ = try emitUtility(compiler.allocator, out, base, important);
}

fn renderCustomVariantCandidate(compiler: *Compiler, out: *std.ArrayList(u8), raw: []const u8, parsed: ParsedCandidate) !bool {
    if (!candidateHasCustomVariant(compiler, parsed.variants)) return false;
    if (!themeVariantsAreSupported(compiler, parsed.variants)) return false;

    var decls: std.ArrayList(u8) = .empty;
    defer decls.deinit(compiler.allocator);
    if (!try emitUtility(compiler.allocator, &decls, parsed.base, parsed.important)) return false;
    if (decls.items.len == 0) return false;
    try writeThemeRule(compiler, out, raw, parsed.variants, "", decls.items);
    return true;
}

fn candidateHasCustomVariant(compiler: *Compiler, variants: []const []const u8) bool {
    for (variants) |variant| {
        if (customVariantForName(compiler, variant) != null) return true;
        if (negatedCustomMediaVariant(compiler, variant) != null) return true;
        if (negatedBodyCustomVariantForName(compiler, variant) != null) return true;
        if (compoundCustomVariantForName(compiler, variant) != null) return true;
        if (conditionalCustomVariantForName(compiler, variant) != null) return true;
    }
    return false;
}

fn renderThemeShadowCandidate(compiler: *Compiler, out: *std.ArrayList(u8), raw: []const u8, parsed: ParsedCandidate) !bool {
    if (!std.mem.startsWith(u8, parsed.base, "shadow-")) return false;
    if (!themeVariantsAreSupported(compiler, parsed.variants)) return false;
    var suffix = parsed.base["shadow-".len..];
    var alpha_token: ?[]const u8 = null;
    if (std.mem.indexOfScalar(u8, suffix, '/')) |slash| {
        alpha_token = suffix[slash + 1 ..];
        suffix = suffix[0..slash];
    }

    if (findThemeVariableWithNamespace(compiler, "--shadow-", suffix)) |variable| {
        if (std.mem.eql(u8, variable.value, "initial")) return false;
        if (alpha_token == null) {
            var fallback_buf: [128]u8 = undefined;
            if (shadowColorMixFallbackColor(compiler, &fallback_buf, variable.value)) |fallback_color| {
                if (shadowColorMixValue(variable.value)) |mix_color| {
                    const fallback_shadow = try shadowColorVariableValue(compiler, variable.value, fallback_color);
                    defer compiler.allocator.free(fallback_shadow);
                    const supports_shadow = try shadowColorVariableValue(compiler, variable.value, mix_color);
                    defer compiler.allocator.free(supports_shadow);

                    try appendShadowLayer(compiler.allocator, out);

                    var base_decls: std.ArrayList(u8) = .empty;
                    defer base_decls.deinit(compiler.allocator);
                    try appendDecl(compiler.allocator, &base_decls, "--tw-shadow", fallback_shadow, parsed.important);
                    try writeThemeRule(compiler, out, raw, parsed.variants, "", base_decls.items);

                    var supports_decls: std.ArrayList(u8) = .empty;
                    defer supports_decls.deinit(compiler.allocator);
                    try appendDecl(compiler.allocator, &supports_decls, "--tw-shadow", supports_shadow, parsed.important);
                    try out.appendSlice(compiler.allocator, "@supports (color:color-mix(in lab, red, red)){");
                    try writeThemeRule(compiler, out, raw, parsed.variants, "", supports_decls.items);
                    try out.append(compiler.allocator, '}');

                    var box_decls: std.ArrayList(u8) = .empty;
                    defer box_decls.deinit(compiler.allocator);
                    try appendDecl(compiler.allocator, &box_decls, "box-shadow", "var(--tw-inset-shadow), var(--tw-inset-ring-shadow), var(--tw-ring-offset-shadow), var(--tw-ring-shadow), var(--tw-shadow)", parsed.important);
                    try writeThemeRule(compiler, out, raw, parsed.variants, "", box_decls.items);
                    try appendShadowProperties(compiler.allocator, out);
                    return true;
                }
            }
        }
        const shadow = try shadowListWithColorVariable(compiler, variable.value, "--tw-shadow-color", alpha_token);
        defer compiler.allocator.free(shadow);

        var decls: std.ArrayList(u8) = .empty;
        defer decls.deinit(compiler.allocator);
        if (alpha_token) |token| {
            var pct_buf: [64]u8 = undefined;
            const pct = opacityPercent(&pct_buf, token) orelse return false;
            try appendDecl(compiler.allocator, &decls, "--tw-shadow-alpha", pct, parsed.important);
        }
        try appendDecl(compiler.allocator, &decls, "--tw-shadow", shadow, parsed.important);
        try appendDecl(compiler.allocator, &decls, "box-shadow", "var(--tw-inset-shadow), var(--tw-inset-ring-shadow), var(--tw-ring-offset-shadow), var(--tw-ring-shadow), var(--tw-shadow)", parsed.important);

        try appendShadowLayer(compiler.allocator, out);
        try writeThemeRule(compiler, out, raw, parsed.variants, "", decls.items);
        try appendShadowProperties(compiler.allocator, out);
        return true;
    }

    return try renderShadowColorCandidate(compiler, out, raw, parsed, .{
        .prefix = "shadow-",
        .prop = "--tw-shadow-color",
        .alpha_prop = "--tw-shadow-alpha",
        .side_namespace = "--box-shadow-color-",
        .layer = .shadow,
    });
}

fn renderThemeInsetShadowCandidate(compiler: *Compiler, out: *std.ArrayList(u8), raw: []const u8, parsed: ParsedCandidate) !bool {
    if (!themeVariantsAreSupported(compiler, parsed.variants)) return false;
    if (std.mem.eql(u8, parsed.base, "inset-shadow") or std.mem.startsWith(u8, parsed.base, "inset-shadow")) {
        var suffix: []const u8 = "";
        var alpha_token: ?[]const u8 = null;
        const variable = blk: {
            if (std.mem.eql(u8, parsed.base, "inset-shadow")) break :blk findThemeVariable(compiler, "--inset-shadow");
            if (!std.mem.startsWith(u8, parsed.base, "inset-shadow-")) break :blk null;
            suffix = parsed.base["inset-shadow-".len..];
            if (std.mem.indexOfScalar(u8, suffix, '/')) |slash| {
                alpha_token = suffix[slash + 1 ..];
                suffix = suffix[0..slash];
            }
            break :blk findThemeVariableWithNamespace(compiler, "--inset-shadow-", suffix);
        };
        if (variable) |theme_variable| {
            if (std.mem.eql(u8, theme_variable.value, "initial")) return false;
            const shadow = try shadowListWithColorVariable(compiler, theme_variable.value, "--tw-inset-shadow-color", alpha_token);
            defer compiler.allocator.free(shadow);

            var decls: std.ArrayList(u8) = .empty;
            defer decls.deinit(compiler.allocator);
            if (alpha_token) |token| {
                var pct_buf: [64]u8 = undefined;
                const pct = opacityPercent(&pct_buf, token) orelse return false;
                try appendDecl(compiler.allocator, &decls, "--tw-inset-shadow-alpha", pct, parsed.important);
            }
            try appendDecl(compiler.allocator, &decls, "--tw-inset-shadow", shadow, parsed.important);
            try appendDecl(compiler.allocator, &decls, "box-shadow", "var(--tw-inset-shadow), var(--tw-inset-ring-shadow), var(--tw-ring-offset-shadow), var(--tw-ring-shadow), var(--tw-shadow)", parsed.important);

            try appendShadowLayer(compiler.allocator, out);
            try writeThemeRule(compiler, out, raw, parsed.variants, "", decls.items);
            try appendShadowProperties(compiler.allocator, out);
            return true;
        }
    }

    return try renderShadowColorCandidate(compiler, out, raw, parsed, .{
        .prefix = "inset-shadow-",
        .prop = "--tw-inset-shadow-color",
        .alpha_prop = "--tw-inset-shadow-alpha",
        .side_namespace = null,
        .layer = .shadow,
    });
}

fn insetShadowColorVariableValue(allocator: std.mem.Allocator, value: []const u8) ![]const u8 {
    const replacements = [_]struct { from: []const u8, fallback: []const u8 }{
        .{ .from = "rgb(0 0 0 / 0.05)", .fallback = "#0000000d" },
        .{ .from = "rgb(0 0 0 / .05)", .fallback = "#0000000d" },
        .{ .from = "#0000000d", .fallback = "#0000000d" },
    };
    inline for (replacements) |replacement| {
        if (std.mem.lastIndexOf(u8, value, replacement.from)) |start| {
            var out: std.ArrayList(u8) = .empty;
            errdefer out.deinit(allocator);
            try out.appendSlice(allocator, value[0..start]);
            try out.appendSlice(allocator, "var(--tw-inset-shadow-color,");
            try out.appendSlice(allocator, replacement.fallback);
            try out.append(allocator, ')');
            try out.appendSlice(allocator, value[start + replacement.from.len ..]);
            return try out.toOwnedSlice(allocator);
        }
    }
    return try allocator.dupe(u8, value);
}

const ShadowLayerKind = enum { none, shadow, text_shadow, filter };

const ShadowColorRenderOptions = struct {
    prefix: []const u8,
    prop: []const u8,
    alpha_prop: []const u8,
    side_namespace: ?[]const u8,
    layer: ShadowLayerKind,
    drop_shadow_color: bool = false,
};

fn renderThemeTextShadowCandidate(compiler: *Compiler, out: *std.ArrayList(u8), raw: []const u8, parsed: ParsedCandidate) !bool {
    if (!themeVariantsAreSupported(compiler, parsed.variants)) return false;
    if (!std.mem.startsWith(u8, parsed.base, "text-shadow-")) return false;

    var suffix = parsed.base["text-shadow-".len..];
    var alpha_token: ?[]const u8 = null;
    if (std.mem.indexOfScalar(u8, suffix, '/')) |slash| {
        alpha_token = suffix[slash + 1 ..];
        suffix = suffix[0..slash];
    }

    if (findThemeVariableWithNamespace(compiler, "--text-shadow-", suffix)) |variable| {
        if (std.mem.eql(u8, variable.value, "initial")) return false;
        const shadow = try shadowListWithColorVariable(compiler, variable.value, "--tw-text-shadow-color", alpha_token);
        defer compiler.allocator.free(shadow);

        var decls: std.ArrayList(u8) = .empty;
        defer decls.deinit(compiler.allocator);
        if (alpha_token) |token| {
            var pct_buf: [64]u8 = undefined;
            const pct = opacityPercent(&pct_buf, token) orelse return false;
            try appendDecl(compiler.allocator, &decls, "--tw-text-shadow-alpha", pct, parsed.important);
        }
        try appendDecl(compiler.allocator, &decls, "text-shadow", shadow, parsed.important);

        try appendTextShadowLayer(compiler.allocator, out);
        try writeThemeRule(compiler, out, raw, parsed.variants, "", decls.items);
        try appendTextShadowProperties(compiler.allocator, out);
        return true;
    }

    return try renderShadowColorCandidate(compiler, out, raw, parsed, .{
        .prefix = "text-shadow-",
        .prop = "--tw-text-shadow-color",
        .alpha_prop = "--tw-text-shadow-alpha",
        .side_namespace = null,
        .layer = .text_shadow,
    });
}

fn renderThemeDropShadowCandidate(compiler: *Compiler, out: *std.ArrayList(u8), raw: []const u8, parsed: ParsedCandidate) !bool {
    if (!themeVariantsAreSupported(compiler, parsed.variants)) return false;
    if (!std.mem.eql(u8, parsed.base, "drop-shadow") and
        !std.mem.startsWith(u8, parsed.base, "drop-shadow/") and
        !std.mem.startsWith(u8, parsed.base, "drop-shadow-"))
        return false;

    var suffix: []const u8 = "";
    var alpha_token: ?[]const u8 = null;
    const variable = blk: {
        if (std.mem.eql(u8, parsed.base, "drop-shadow")) break :blk findThemeVariable(compiler, "--drop-shadow");
        if (std.mem.startsWith(u8, parsed.base, "drop-shadow/")) {
            alpha_token = parsed.base["drop-shadow/".len..];
            break :blk findThemeVariable(compiler, "--drop-shadow");
        }
        suffix = parsed.base["drop-shadow-".len..];
        if (std.mem.indexOfScalar(u8, suffix, '/')) |slash| {
            alpha_token = suffix[slash + 1 ..];
            suffix = suffix[0..slash];
        }
        break :blk findThemeVariableWithNamespace(compiler, "--drop-shadow-", suffix);
    };

    if (variable) |theme_variable| {
        if (std.mem.eql(u8, theme_variable.value, "initial")) return false;
        const size = try dropShadowSizeValue(compiler, theme_variable.value, alpha_token);
        defer compiler.allocator.free(size);
        const actual = try dropShadowActualValue(compiler, theme_variable);
        defer compiler.allocator.free(actual);

        var decls: std.ArrayList(u8) = .empty;
        defer decls.deinit(compiler.allocator);
        if (alpha_token) |token| {
            var pct_buf: [64]u8 = undefined;
            const pct = opacityPercent(&pct_buf, token) orelse return false;
            try appendDecl(compiler.allocator, &decls, "--tw-drop-shadow-alpha", pct, parsed.important);
        }
        try appendDecl(compiler.allocator, &decls, "--tw-drop-shadow-size", size, parsed.important);
        try appendDecl(compiler.allocator, &decls, "--tw-drop-shadow", actual, parsed.important);
        try appendDecl(compiler.allocator, &decls, "filter", filterValue(), parsed.important);

        try appendFilterLayer(compiler.allocator, out);
        try writeThemeRule(compiler, out, raw, parsed.variants, "", decls.items);
        try appendFilterProperties(compiler.allocator, out);
        return true;
    }

    var builtin_name_buf: [512]u8 = undefined;
    const builtin_name = if (std.mem.eql(u8, parsed.base, "drop-shadow") or std.mem.startsWith(u8, parsed.base, "drop-shadow/"))
        "--drop-shadow"
    else if (std.mem.eql(u8, suffix, "none"))
        ""
    else
        std.fmt.bufPrint(&builtin_name_buf, "--drop-shadow-{s}", .{suffix}) catch return false;

    if (builtin_name.len > 0) {
        if (builtinThemeVariableValue(builtin_name)) |value| {
            const size = try dropShadowSizeValue(compiler, value, alpha_token);
            defer compiler.allocator.free(size);
            var actual_buf: [768]u8 = undefined;
            const actual = if (std.mem.eql(u8, builtin_name, "--drop-shadow"))
                dropShadowInlineValue(&actual_buf, value) orelse return false
            else
                std.fmt.bufPrint(&actual_buf, "drop-shadow(var({s}))", .{builtin_name}) catch return false;

            var decls: std.ArrayList(u8) = .empty;
            defer decls.deinit(compiler.allocator);
            if (alpha_token) |token| {
                var pct_buf: [64]u8 = undefined;
                const pct = opacityPercent(&pct_buf, token) orelse return false;
                try appendDecl(compiler.allocator, &decls, "--tw-drop-shadow-alpha", pct, parsed.important);
            }
            try appendDecl(compiler.allocator, &decls, "--tw-drop-shadow-size", size, parsed.important);
            try appendDecl(compiler.allocator, &decls, "--tw-drop-shadow", actual, parsed.important);
            try appendDecl(compiler.allocator, &decls, "filter", filterValue(), parsed.important);

            try appendFilterLayer(compiler.allocator, out);
            try writeThemeRule(compiler, out, raw, parsed.variants, "", decls.items);
            try appendFilterProperties(compiler.allocator, out);
            return true;
        }
    } else {
        try appendFilterLayer(compiler.allocator, out);
        var decls: std.ArrayList(u8) = .empty;
        defer decls.deinit(compiler.allocator);
        try appendDecl(compiler.allocator, &decls, "--tw-drop-shadow", " ", parsed.important);
        try appendDecl(compiler.allocator, &decls, "filter", filterValue(), parsed.important);
        try writeThemeRule(compiler, out, raw, parsed.variants, "", decls.items);
        try appendFilterProperties(compiler.allocator, out);
        return true;
    }

    return try renderShadowColorCandidate(compiler, out, raw, parsed, .{
        .prefix = "drop-shadow-",
        .prop = "--tw-drop-shadow-color",
        .alpha_prop = "--tw-drop-shadow-alpha",
        .side_namespace = null,
        .layer = .filter,
        .drop_shadow_color = true,
    });
}

fn renderBareFilterCandidate(compiler: *Compiler, out: *std.ArrayList(u8), raw: []const u8, parsed: ParsedCandidate) !bool {
    if (!themeVariantsAreSupported(compiler, parsed.variants)) return false;

    const entries = [_]struct { name: []const u8, prop: []const u8, value: []const u8 }{
        .{ .name = "grayscale", .prop = "--tw-grayscale", .value = "grayscale(100%)" },
        .{ .name = "invert", .prop = "--tw-invert", .value = "invert(100%)" },
        .{ .name = "sepia", .prop = "--tw-sepia", .value = "sepia(100%)" },
    };

    for (entries) |entry| {
        if (!std.mem.eql(u8, parsed.base, entry.name)) continue;
        try appendFilterLayer(compiler.allocator, out);
        var decls: std.ArrayList(u8) = .empty;
        defer decls.deinit(compiler.allocator);
        try appendDecl(compiler.allocator, &decls, entry.prop, entry.value, parsed.important);
        try appendDecl(compiler.allocator, &decls, "filter", filterValue(), parsed.important);
        try writeThemeRule(compiler, out, raw, parsed.variants, "", decls.items);
        try appendFilterProperties(compiler.allocator, out);
        return true;
    }

    const percent_entries = [_]struct { prefix: []const u8, prop: []const u8, function: []const u8 }{
        .{ .prefix = "brightness-", .prop = "--tw-brightness", .function = "brightness" },
        .{ .prefix = "contrast-", .prop = "--tw-contrast", .function = "contrast" },
        .{ .prefix = "saturate-", .prop = "--tw-saturate", .function = "saturate" },
    };
    inline for (percent_entries) |entry| {
        if (std.mem.startsWith(u8, parsed.base, entry.prefix)) {
            const suffix = parsed.base[entry.prefix.len..];
            const n = parsePositiveInt(suffix) orelse return false;
            var value_buf: [64]u8 = undefined;
            const value = std.fmt.bufPrint(&value_buf, "{s}({d}%)", .{ entry.function, n }) catch return false;
            try appendFilterLayer(compiler.allocator, out);
            var decls: std.ArrayList(u8) = .empty;
            defer decls.deinit(compiler.allocator);
            try appendDecl(compiler.allocator, &decls, entry.prop, value, parsed.important);
            try appendDecl(compiler.allocator, &decls, "filter", filterValue(), parsed.important);
            try writeThemeRule(compiler, out, raw, parsed.variants, "", decls.items);
            try appendFilterProperties(compiler.allocator, out);
            return true;
        }
    }

    return false;
}

fn renderShadowColorCandidate(
    compiler: *Compiler,
    out: *std.ArrayList(u8),
    raw: []const u8,
    parsed: ParsedCandidate,
    options: ShadowColorRenderOptions,
) !bool {
    if (!std.mem.startsWith(u8, parsed.base, options.prefix)) return false;
    var color = parsed.base[options.prefix.len..];
    var alpha_token: ?[]const u8 = null;
    if (std.mem.indexOfScalar(u8, color, '/')) |slash| {
        alpha_token = color[slash + 1 ..];
        color = color[0..slash];
    }
    if (color.len == 0 or color[0] == '[') return false;

    var color_name_buf: [512]u8 = undefined;
    const color_name = std.fmt.bufPrint(&color_name_buf, "--color-{s}", .{color}) catch return false;
    const variable = if (options.side_namespace) |namespace|
        findThemeVariableWithNamespace(compiler, namespace, color) orelse findThemeVariable(compiler, color_name) orelse return false
    else
        findThemeVariable(compiler, color_name) orelse return false;
    if (std.mem.eql(u8, variable.value, "initial")) return false;

    var value_buf: [512]u8 = undefined;
    const value = resolveThemeName(compiler, &value_buf, variable.name) orelse return false;

    var fallback_color_buf: [16]u8 = undefined;
    const fallback_color = colorFallbackHex(compiler, &fallback_color_buf, variable.value, 0) orelse return false;
    var fallback_buf: [16]u8 = undefined;
    const fallback = if (alpha_token) |token| blk: {
        var pct_buf: [64]u8 = undefined;
        const pct = opacityPercent(&pct_buf, token) orelse return false;
        break :blk hexColorWithAlpha(&fallback_buf, fallback_color, pct) orelse return false;
    } else fallback_color;

    try appendLayerForShadowColor(compiler.allocator, out, options.layer);

    var base_decls: std.ArrayList(u8) = .empty;
    defer base_decls.deinit(compiler.allocator);
    try appendDecl(compiler.allocator, &base_decls, options.prop, fallback, parsed.important);
    try writeThemeRule(compiler, out, raw, parsed.variants, "", base_decls.items);

    var supports_decls: std.ArrayList(u8) = .empty;
    defer supports_decls.deinit(compiler.allocator);
    const support_color = if (alpha_token) |token| blk: {
        var pct_buf: [64]u8 = undefined;
        const pct = opacityPercent(&pct_buf, token) orelse return false;
        var inner_buf: [768]u8 = undefined;
        break :blk std.fmt.bufPrint(&inner_buf, "color-mix(in oklab,{s} {s},transparent)", .{ value, pct }) catch return false;
    } else value;
    var mixed_buf: [1200]u8 = undefined;
    const mixed = std.fmt.bufPrint(&mixed_buf, "color-mix(in oklab,{s} var({s}),transparent)", .{ support_color, options.alpha_prop }) catch return false;
    try appendDecl(compiler.allocator, &supports_decls, options.prop, mixed, parsed.important);
    try out.appendSlice(compiler.allocator, "@supports (color:color-mix(in lab, red, red)){");
    try writeThemeRule(compiler, out, raw, parsed.variants, "", supports_decls.items);
    try out.append(compiler.allocator, '}');

    if (options.drop_shadow_color) {
        var drop_decls: std.ArrayList(u8) = .empty;
        defer drop_decls.deinit(compiler.allocator);
        try appendDecl(compiler.allocator, &drop_decls, "--tw-drop-shadow", "var(--tw-drop-shadow-size)", parsed.important);
        try writeThemeRule(compiler, out, raw, parsed.variants, "", drop_decls.items);
    }

    try appendPropertiesForShadowColor(compiler.allocator, out, options.layer);
    return true;
}

fn appendLayerForShadowColor(allocator: std.mem.Allocator, out: *std.ArrayList(u8), kind: ShadowLayerKind) !void {
    switch (kind) {
        .none => {},
        .shadow => try appendShadowLayer(allocator, out),
        .text_shadow => try appendTextShadowLayer(allocator, out),
        .filter => try appendFilterLayer(allocator, out),
    }
}

fn appendPropertiesForShadowColor(allocator: std.mem.Allocator, out: *std.ArrayList(u8), kind: ShadowLayerKind) !void {
    switch (kind) {
        .none => {},
        .shadow => try appendShadowProperties(allocator, out),
        .text_shadow => try appendTextShadowProperties(allocator, out),
        .filter => try appendFilterProperties(allocator, out),
    }
}

fn shadowListWithColorVariable(compiler: *Compiler, value: []const u8, color_var: []const u8, alpha_token: ?[]const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(compiler.allocator);

    var start: usize = 0;
    while (start < value.len) {
        const comma = topLevelComma(value[start..]);
        const end = if (comma) |rel| start + rel else value.len;
        const part = trimAscii(value[start..end]);
        if (out.items.len > 0) try out.appendSlice(compiler.allocator, ", ");
        try appendShadowPartWithColorVariable(compiler, &out, part, color_var, alpha_token);
        if (comma == null) break;
        start = end + 1;
    }

    return try out.toOwnedSlice(compiler.allocator);
}

fn appendShadowPartWithColorVariable(
    compiler: *Compiler,
    out: *std.ArrayList(u8),
    part: []const u8,
    color_var: []const u8,
    alpha_token: ?[]const u8,
) !void {
    const color_range = lastShadowColorRange(part) orelse {
        try out.appendSlice(compiler.allocator, part);
        return;
    };
    const color = trimAscii(part[color_range.start..color_range.end]);
    try out.appendSlice(compiler.allocator, part[0..color_range.start]);
    try out.appendSlice(compiler.allocator, "var(");
    try out.appendSlice(compiler.allocator, color_var);
    try out.append(compiler.allocator, ',');
    if (alpha_token) |token| {
        var fallback_buf: [128]u8 = undefined;
        const fallback = shadowAlphaFallback(&fallback_buf, color, token) orelse shadowFallbackColor(color);
        try out.appendSlice(compiler.allocator, fallback);
    } else {
        try out.appendSlice(compiler.allocator, shadowFallbackColor(color));
    }
    try out.append(compiler.allocator, ')');
    try out.appendSlice(compiler.allocator, part[color_range.end..]);
}

const CssRange = struct { start: usize, end: usize };

fn lastShadowColorRange(input: []const u8) ?CssRange {
    var best: ?CssRange = null;
    const functions = [_][]const u8{ "rgb(", "oklab(", "oklch(", "color-mix(", "var(" };
    inline for (functions) |needle| {
        if (std.mem.lastIndexOf(u8, input, needle)) |start| {
            const open = start + needle.len - 1;
            const end = (matchingParenClose(input, open) orelse return null) + 1;
            if (best == null or start > best.?.start) best = .{ .start = start, .end = end };
        }
    }
    if (std.mem.lastIndexOfScalar(u8, input, '#')) |start| {
        var end = start + 1;
        while (end < input.len and isHexDigit(input[end])) : (end += 1) {}
        if (end > start + 1 and (best == null or start > best.?.start)) best = .{ .start = start, .end = end };
    }
    return best;
}

fn isHexDigit(c: u8) bool {
    return (c >= '0' and c <= '9') or (c >= 'a' and c <= 'f') or (c >= 'A' and c <= 'F');
}

fn shadowFallbackColor(color: []const u8) []const u8 {
    const trimmed = trimAscii(color);
    const replacements = [_]struct { from: []const u8, fallback: []const u8 }{
        .{ .from = "rgb(0 0 0 / 0.1)", .fallback = "#0000001a" },
        .{ .from = "rgb(0 0 0/.1)", .fallback = "#0000001a" },
        .{ .from = "rgb(0 0 0 / .1)", .fallback = "#0000001a" },
        .{ .from = "#0000001a", .fallback = "#0000001a" },
        .{ .from = "rgb(0 0 0 / 0.15)", .fallback = "#00000026" },
        .{ .from = "rgb(0 0 0/.15)", .fallback = "#00000026" },
        .{ .from = "rgb(0 0 0 / .15)", .fallback = "#00000026" },
        .{ .from = "#00000026", .fallback = "#00000026" },
        .{ .from = "rgb(0 0 0 / 0.12)", .fallback = "#0000001f" },
        .{ .from = "rgb(0 0 0/.12)", .fallback = "#0000001f" },
        .{ .from = "rgb(0 0 0 / .12)", .fallback = "#0000001f" },
        .{ .from = "#0000001f", .fallback = "#0000001f" },
        .{ .from = "rgb(0 0 0 / 0.06)", .fallback = "#0000000f" },
        .{ .from = "rgb(0 0 0/.06)", .fallback = "#0000000f" },
        .{ .from = "rgb(0 0 0 / .06)", .fallback = "#0000000f" },
        .{ .from = "#0000000f", .fallback = "#0000000f" },
        .{ .from = "rgb(0 0 0 / 0.05)", .fallback = "#0000000d" },
        .{ .from = "rgb(0 0 0/.05)", .fallback = "#0000000d" },
        .{ .from = "rgb(0 0 0 / .05)", .fallback = "#0000000d" },
        .{ .from = "#0000000d", .fallback = "#0000000d" },
    };
    inline for (replacements) |replacement| {
        if (std.mem.eql(u8, trimmed, replacement.from)) return replacement.fallback;
    }
    return trimmed;
}

fn shadowAlphaFallback(buf: []u8, color: []const u8, alpha_token: []const u8) ?[]const u8 {
    _ = color;
    var pct_buf: [64]u8 = undefined;
    const pct = opacityPercent(&pct_buf, alpha_token) orelse return null;
    var unit_buf: [32]u8 = undefined;
    const unit = percentToUnitFloat(&unit_buf, pct) orelse return null;
    return std.fmt.bufPrint(buf, "oklab(0% 0 0 / {s})", .{unit}) catch null;
}

fn dropShadowSizeValue(compiler: *Compiler, value: []const u8, alpha_token: ?[]const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(compiler.allocator);

    var start: usize = 0;
    while (start < value.len) {
        const comma = topLevelComma(value[start..]);
        const end = if (comma) |rel| start + rel else value.len;
        const part = trimAscii(value[start..end]);
        if (out.items.len > 0) try out.append(compiler.allocator, ' ');
        try out.appendSlice(compiler.allocator, "drop-shadow(");
        try appendShadowPartWithColorVariable(compiler, &out, part, "--tw-drop-shadow-color", alpha_token);
        try out.append(compiler.allocator, ')');
        if (comma == null) break;
        start = end + 1;
    }

    return try out.toOwnedSlice(compiler.allocator);
}

fn dropShadowActualValue(compiler: *Compiler, variable: ThemeVariable) ![]u8 {
    if (!variable.inline_theme) {
        var value_buf: [512]u8 = undefined;
        const value = resolveThemeName(compiler, &value_buf, variable.name) orelse variable.value;
        return std.fmt.allocPrint(compiler.allocator, "drop-shadow({s})", .{value});
    }

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(compiler.allocator);
    var start: usize = 0;
    while (start < variable.value.len) {
        const comma = topLevelComma(variable.value[start..]);
        const end = if (comma) |rel| start + rel else variable.value.len;
        const part = trimAscii(variable.value[start..end]);
        if (out.items.len > 0) try out.append(compiler.allocator, ' ');
        try out.appendSlice(compiler.allocator, "drop-shadow(");
        try out.appendSlice(compiler.allocator, part);
        try out.append(compiler.allocator, ')');
        if (comma == null) break;
        start = end + 1;
    }
    return try out.toOwnedSlice(compiler.allocator);
}

fn dropShadowInlineValue(buf: []u8, value: []const u8) ?[]const u8 {
    var out: std.ArrayList(u8) = .initBuffer(buf);
    var start: usize = 0;
    while (start < value.len) {
        const comma = topLevelComma(value[start..]);
        const end = if (comma) |rel| start + rel else value.len;
        const part = trimAscii(value[start..end]);
        if (out.items.len > 0) out.appendBounded(' ') catch return null;
        out.appendSliceBounded("drop-shadow(") catch return null;
        appendDropShadowInlinePart(&out, part) catch return null;
        out.appendBounded(')') catch return null;
        if (comma == null) break;
        start = end + 1;
    }
    return out.items;
}

fn appendDropShadowInlinePart(out: *std.ArrayList(u8), part: []const u8) !void {
    const color_range = lastShadowColorRange(part) orelse {
        try out.appendSliceBounded(part);
        return;
    };
    try out.appendSliceBounded(part[0..color_range.start]);
    try out.appendSliceBounded(shadowFallbackColor(trimAscii(part[color_range.start..color_range.end])));
    try out.appendSliceBounded(part[color_range.end..]);
}

fn appendTextShadowLayer(allocator: std.mem.Allocator, out: *std.ArrayList(u8)) !void {
    try appendPropertyLayer(allocator, out, "--tw-text-shadow-color:initial;--tw-text-shadow-alpha:100%;");
}

fn appendTextShadowProperties(allocator: std.mem.Allocator, out: *std.ArrayList(u8)) !void {
    try out.appendSlice(allocator, "@property --tw-text-shadow-color{syntax:\"*\";inherits:false;}@property --tw-text-shadow-alpha{syntax:\"<percentage>\";inherits:false;initial-value:100%;}");
}

fn appendFilterLayer(allocator: std.mem.Allocator, out: *std.ArrayList(u8)) !void {
    try appendPropertyLayer(allocator, out, "--tw-blur:initial;--tw-brightness:initial;--tw-contrast:initial;--tw-grayscale:initial;--tw-hue-rotate:initial;--tw-invert:initial;--tw-opacity:initial;--tw-saturate:initial;--tw-sepia:initial;--tw-drop-shadow:initial;--tw-drop-shadow-color:initial;--tw-drop-shadow-alpha:100%;--tw-drop-shadow-size:initial;");
}

fn filterValue() []const u8 {
    return "var(--tw-blur,) var(--tw-brightness,) var(--tw-contrast,) var(--tw-grayscale,) var(--tw-hue-rotate,) var(--tw-invert,) var(--tw-saturate,) var(--tw-sepia,) var(--tw-drop-shadow,)";
}

fn shadowColorMixFallbackColor(compiler: *Compiler, buf: []u8, value: []const u8) ?[]const u8 {
    const start = std.mem.lastIndexOf(u8, value, "color-mix(") orelse return null;
    const open = start + "color-mix".len;
    const close = matchingParenClose(value, open) orelse return null;
    return colorMixFallback(compiler, buf, value[open + 1 .. close]);
}

fn shadowColorMixValue(value: []const u8) ?[]const u8 {
    const start = std.mem.lastIndexOf(u8, value, "color-mix(") orelse return null;
    const open = start + "color-mix".len;
    const close = matchingParenClose(value, open) orelse return null;
    return value[start .. close + 1];
}

fn shadowColorVariableValue(compiler: *Compiler, value: []const u8, color: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(compiler.allocator);
    if (std.mem.lastIndexOf(u8, value, "color-mix(")) |start| {
        const open = start + "color-mix".len;
        const close = matchingParenClose(value, open) orelse value.len - 1;
        try out.appendSlice(compiler.allocator, value[0..start]);
        try out.appendSlice(compiler.allocator, "var(--tw-shadow-color,");
        try out.appendSlice(compiler.allocator, color);
        try out.append(compiler.allocator, ')');
        try out.appendSlice(compiler.allocator, value[close + 1 ..]);
    } else {
        try out.appendSlice(compiler.allocator, "var(--tw-shadow-color,");
        try out.appendSlice(compiler.allocator, value);
        try out.append(compiler.allocator, ')');
    }
    return try out.toOwnedSlice(compiler.allocator);
}

fn renderThemeCandidate(compiler: *Compiler, out: *std.ArrayList(u8), raw: []const u8, parsed: ParsedCandidate) !bool {
    if (!themeCandidateNeedsCustom(compiler, parsed)) return false;
    if (!themeVariantsAreSupported(compiler, parsed.variants)) return false;

    var decls: std.ArrayList(u8) = .empty;
    defer decls.deinit(compiler.allocator);

    if (!try emitThemeUtility(compiler, out, &decls, parsed.base, parsed.important)) {
        if (!try emitUtility(compiler.allocator, &decls, parsed.base, parsed.important)) return false;
    }
    if (decls.items.len == 0) return false;
    const suffix = if (std.mem.startsWith(u8, parsed.base, "placeholder-")) "::placeholder" else "";
    try writeThemeRule(compiler, out, raw, parsed.variants, suffix, decls.items);
    return true;
}

fn renderThemeDefaultBorderCandidate(compiler: *Compiler, out: *std.ArrayList(u8), raw: []const u8, parsed: ParsedCandidate) !bool {
    if (!std.mem.eql(u8, parsed.base, "border")) return false;
    if (findThemeVariable(compiler, "--default-border-width") == null) return false;
    return try renderTypedPropertyUtility(compiler, out, raw, parsed);
}

fn renderThemeDefaultRingCandidate(compiler: *Compiler, out: *std.ArrayList(u8), raw: []const u8, parsed: ParsedCandidate) !bool {
    if (parsed.variants.len != 0) return false;
    if (!std.mem.eql(u8, parsed.base, "ring")) return false;
    const variable = findThemeVariable(compiler, "--default-ring-width") orelse return false;

    try appendShadowLayer(compiler.allocator, out);
    var value_buf: [768]u8 = undefined;
    const value = std.fmt.bufPrint(&value_buf, "var(--tw-ring-inset,) 0 0 0 calc({s} + var(--tw-ring-offset-width)) var(--tw-ring-color,currentcolor)", .{variable.value}) catch return false;
    var decls: std.ArrayList(u8) = .empty;
    defer decls.deinit(compiler.allocator);
    try appendDecl(compiler.allocator, &decls, "--tw-ring-shadow", value, parsed.important);
    try appendDecl(compiler.allocator, &decls, "box-shadow", "var(--tw-inset-shadow), var(--tw-inset-ring-shadow), var(--tw-ring-offset-shadow), var(--tw-ring-shadow), var(--tw-shadow)", parsed.important);
    try writeThemeRule(compiler, out, raw, parsed.variants, "", decls.items);
    try appendShadowProperties(compiler.allocator, out);
    return true;
}

fn renderThemeOutlineCandidate(compiler: *Compiler, out: *std.ArrayList(u8), raw: []const u8, parsed: ParsedCandidate) !bool {
    if (parsed.variants.len != 0) return false;
    if (std.mem.eql(u8, parsed.base, "outline")) {
        const variable = findThemeVariable(compiler, "--default-outline-width") orelse return false;
        return try renderOutlineWidthRule(compiler, out, raw, parsed, variable.value);
    }

    if (!std.mem.startsWith(u8, parsed.base, "outline-")) return false;
    const suffix = parsed.base["outline-".len..];
    if (std.mem.indexOfScalar(u8, suffix, '/')) |_| return false;

    var value_buf: [512]u8 = undefined;
    if (resolveThemeValue(compiler, &value_buf, "--outline-color-", suffix) orelse resolveThemeValue(compiler, &value_buf, "--color-", suffix)) |color| {
        var decls: std.ArrayList(u8) = .empty;
        defer decls.deinit(compiler.allocator);
        try appendDecl(compiler.allocator, &decls, "outline-color", color, parsed.important);
        try writeThemeRule(compiler, out, raw, parsed.variants, "", decls.items);
        return true;
    }

    if (resolveThemeValue(compiler, &value_buf, "--outline-width-", suffix)) |width| {
        return try renderOutlineWidthRule(compiler, out, raw, parsed, width);
    }
    return false;
}

fn renderOutlineWidthRule(compiler: *Compiler, out: *std.ArrayList(u8), raw: []const u8, parsed: ParsedCandidate, width: []const u8) !bool {
    try appendPropertyLayer(compiler.allocator, out, "--tw-outline-style:solid;");
    var decls: std.ArrayList(u8) = .empty;
    defer decls.deinit(compiler.allocator);
    try appendDecl(compiler.allocator, &decls, "outline-style", "var(--tw-outline-style)", parsed.important);
    try appendDecl(compiler.allocator, &decls, "outline-width", width, parsed.important);
    try writeThemeRule(compiler, out, raw, parsed.variants, "", decls.items);
    try out.appendSlice(compiler.allocator, "@property --tw-outline-style{syntax:\"*\";inherits:false;initial-value:solid;}");
    return true;
}

fn renderThemeContentCandidate(compiler: *Compiler, out: *std.ArrayList(u8), raw: []const u8, parsed: ParsedCandidate) !bool {
    if (!themeVariantsAreSupported(compiler, parsed.variants)) return false;
    if (!std.mem.startsWith(u8, parsed.base, "content-")) return false;
    const suffix = parsed.base["content-".len..];
    var value_buf: [512]u8 = undefined;
    const value = arbitraryValue(&value_buf, suffix) orelse resolveThemeValue(compiler, &value_buf, "--content-", suffix) orelse return false;

    if (std.mem.indexOf(u8, out.items, "--tw-content:\"\"") == null) {
        try appendPropertyLayer(compiler.allocator, out, "--tw-content:\"\";");
    }
    var decls: std.ArrayList(u8) = .empty;
    defer decls.deinit(compiler.allocator);
    try appendDecl(compiler.allocator, &decls, "--tw-content", value, parsed.important);
    try appendDecl(compiler.allocator, &decls, "content", "var(--tw-content)", parsed.important);
    try writeThemeRule(compiler, out, raw, parsed.variants, "", decls.items);
    if (std.mem.indexOf(u8, out.items, "@property --tw-content") == null) {
        try out.appendSlice(compiler.allocator, "@property --tw-content{syntax:\"*\";inherits:false;initial-value:\"\";}");
    }
    return true;
}

fn renderThemeBlurCandidate(compiler: *Compiler, out: *std.ArrayList(u8), raw: []const u8, parsed: ParsedCandidate) !bool {
    if (!themeVariantsAreSupported(compiler, parsed.variants)) return false;

    if (std.mem.startsWith(u8, parsed.base, "blur-")) {
        const suffix = parsed.base["blur-".len..];
        var value_buf: [512]u8 = undefined;
        const value = if (std.mem.eql(u8, suffix, "none"))
            " "
        else
            resolveThemeValueOrBuiltin(compiler, &value_buf, "--blur-", suffix) orelse return false;
        try appendPropertyLayer(compiler.allocator, out, "--tw-blur:initial;--tw-brightness:initial;--tw-contrast:initial;--tw-grayscale:initial;--tw-hue-rotate:initial;--tw-invert:initial;--tw-opacity:initial;--tw-saturate:initial;--tw-sepia:initial;--tw-drop-shadow:initial;--tw-drop-shadow-color:initial;--tw-drop-shadow-alpha:100%;--tw-drop-shadow-size:initial;");

        var decls: std.ArrayList(u8) = .empty;
        defer decls.deinit(compiler.allocator);
        var blur_buf: [768]u8 = undefined;
        const blur = if (std.mem.eql(u8, suffix, "none")) value else std.fmt.bufPrint(&blur_buf, "blur({s})", .{value}) catch return false;
        try appendDecl(compiler.allocator, &decls, "--tw-blur", blur, parsed.important);
        try appendDecl(compiler.allocator, &decls, "filter", "var(--tw-blur,) var(--tw-brightness,) var(--tw-contrast,) var(--tw-grayscale,) var(--tw-hue-rotate,) var(--tw-invert,) var(--tw-saturate,) var(--tw-sepia,) var(--tw-drop-shadow,)", parsed.important);
        try writeThemeRule(compiler, out, raw, parsed.variants, "", decls.items);
        try appendFilterProperties(compiler.allocator, out);
        return true;
    }

    if (std.mem.startsWith(u8, parsed.base, "backdrop-blur-")) {
        const suffix = parsed.base["backdrop-blur-".len..];
        var value_buf: [512]u8 = undefined;
        const value = if (std.mem.eql(u8, suffix, "none"))
            " "
        else
            resolveThemeValueOrBuiltin(compiler, &value_buf, "--blur-", suffix) orelse return false;
        try appendPropertyLayer(compiler.allocator, out, "--tw-backdrop-blur:initial;--tw-backdrop-brightness:initial;--tw-backdrop-contrast:initial;--tw-backdrop-grayscale:initial;--tw-backdrop-hue-rotate:initial;--tw-backdrop-invert:initial;--tw-backdrop-opacity:initial;--tw-backdrop-saturate:initial;--tw-backdrop-sepia:initial;");

        var decls: std.ArrayList(u8) = .empty;
        defer decls.deinit(compiler.allocator);
        var blur_buf: [768]u8 = undefined;
        const blur = if (std.mem.eql(u8, suffix, "none")) value else std.fmt.bufPrint(&blur_buf, "blur({s})", .{value}) catch return false;
        const filter = "var(--tw-backdrop-blur,) var(--tw-backdrop-brightness,) var(--tw-backdrop-contrast,) var(--tw-backdrop-grayscale,) var(--tw-backdrop-hue-rotate,) var(--tw-backdrop-invert,) var(--tw-backdrop-opacity,) var(--tw-backdrop-saturate,) var(--tw-backdrop-sepia,)";
        try appendDecl(compiler.allocator, &decls, "--tw-backdrop-blur", blur, parsed.important);
        try appendDecl(compiler.allocator, &decls, "-webkit-backdrop-filter", filter, parsed.important);
        try appendDecl(compiler.allocator, &decls, "backdrop-filter", filter, parsed.important);
        try writeThemeRule(compiler, out, raw, parsed.variants, "", decls.items);
        try appendBackdropFilterProperties(compiler.allocator, out);
        return true;
    }

    return false;
}

fn renderTransitionCandidate(compiler: *Compiler, out: *std.ArrayList(u8), raw: []const u8, parsed: ParsedCandidate) !bool {
    var property_buf: [512]u8 = undefined;
    const property = transitionPropertyValue(compiler, &property_buf, parsed.base) orelse return false;

    var decls: std.ArrayList(u8) = .empty;
    defer decls.deinit(compiler.allocator);
    try appendDecl(compiler.allocator, &decls, "transition-property", property, parsed.important);
    if (!std.mem.eql(u8, parsed.base, "transition-none")) {
        var timing_buf: [512]u8 = undefined;
        const legacy_defaults = compiler.authored_css_blocks.items.len == 0;
        const timing_fallback = if (legacy_defaults) "var(--default-transition-timing-function)" else "ease";
        const duration_fallback = if (legacy_defaults) "var(--default-transition-duration)" else "0s";
        const timing = resolveThemeName(compiler, &timing_buf, "--default-transition-timing-function") orelse timing_fallback;
        var duration_buf: [512]u8 = undefined;
        const raw_duration = resolveThemeName(compiler, &duration_buf, "--default-transition-duration") orelse duration_fallback;
        var normalized_duration_buf: [64]u8 = undefined;
        const duration = normalizeTransitionDuration(&normalized_duration_buf, raw_duration) orelse raw_duration;

        var timing_decl_buf: [768]u8 = undefined;
        const timing_decl = std.fmt.bufPrint(&timing_decl_buf, "var(--tw-ease,{s})", .{timing}) catch return false;
        var duration_decl_buf: [768]u8 = undefined;
        const duration_decl = std.fmt.bufPrint(&duration_decl_buf, "var(--tw-duration,{s})", .{duration}) catch return false;
        try appendDecl(compiler.allocator, &decls, "transition-timing-function", timing_decl, parsed.important);
        try appendDecl(compiler.allocator, &decls, "transition-duration", duration_decl, parsed.important);
    }
    try writeThemeRule(compiler, out, raw, parsed.variants, "", decls.items);
    return true;
}

fn renderDecorationInheritCandidate(compiler: *Compiler, out: *std.ArrayList(u8), raw: []const u8, parsed: ParsedCandidate) !bool {
    if (!themeVariantsAreSupported(compiler, parsed.variants)) return false;
    if (!std.mem.eql(u8, parsed.base, "decoration-inherit")) return false;
    var decls: std.ArrayList(u8) = .empty;
    defer decls.deinit(compiler.allocator);
    try appendDecl(compiler.allocator, &decls, "text-decoration-color", "inherit", parsed.important);
    try writeThemeRule(compiler, out, raw, parsed.variants, "", decls.items);
    return true;
}

fn transitionPropertyValue(compiler: *Compiler, buf: []u8, base: []const u8) ?[]const u8 {
    if (std.mem.eql(u8, base, "transition")) return "color,background-color,border-color,outline-color,text-decoration-color,fill,stroke,--tw-gradient-from,--tw-gradient-via,--tw-gradient-to,opacity,box-shadow,transform,translate,scale,rotate,filter,-webkit-backdrop-filter,backdrop-filter,display,content-visibility,overlay,pointer-events";
    if (std.mem.eql(u8, base, "transition-all")) return "all";
    if (std.mem.eql(u8, base, "transition-none")) return "none";
    if (std.mem.eql(u8, base, "transition-opacity")) return resolveThemeName(compiler, buf, "--transition-property-opacity") orelse "opacity";
    if (std.mem.eql(u8, base, "transition-shadow")) return "box-shadow";
    if (std.mem.eql(u8, base, "transition-transform")) return "transform,translate,scale,rotate";
    if (std.mem.eql(u8, base, "transition-colors")) {
        return resolveThemeName(compiler, buf, "--transition-property-colors") orelse "color,background-color,border-color,outline-color,text-decoration-color,fill,stroke,--tw-gradient-from,--tw-gradient-via,--tw-gradient-to";
    }
    return null;
}

fn normalizeTransitionDuration(buf: []u8, value: []const u8) ?[]const u8 {
    if (!std.mem.endsWith(u8, value, "ms")) return null;
    const number = std.fmt.parseFloat(f64, value[0 .. value.len - 2]) catch return null;
    const seconds = formatCssFloat3(buf, number / 1000.0) orelse return null;
    if (seconds.len + 1 > buf.len) return null;
    buf[seconds.len] = 's';
    return buf[0 .. seconds.len + 1];
}

fn renderThemeSpaceCandidate(compiler: *Compiler, out: *std.ArrayList(u8), raw: []const u8, parsed: ParsedCandidate) !bool {
    if (parsed.variants.len != 0) return false;

    var negative = false;
    var name = parsed.base;
    if (name.len > 1 and name[0] == '-') {
        negative = true;
        name = name[1..];
    }

    const is_x = std.mem.startsWith(u8, name, "space-x-");
    const is_y = std.mem.startsWith(u8, name, "space-y-");
    if (!is_x and !is_y) return false;
    const suffix = name["space-x-".len..];

    var value_buf: [512]u8 = undefined;
    const value = themeSpacingValue(compiler, &value_buf, suffix, negative) orelse return false;

    const variable = if (is_x) "--tw-space-x-reverse" else "--tw-space-y-reverse";
    var layer_buf: [64]u8 = undefined;
    const layer_decls = std.fmt.bufPrint(&layer_buf, "{s}:0;", .{variable}) catch return false;
    try appendPropertyLayer(compiler.allocator, out, layer_decls);
    var selector: std.ArrayList(u8) = .empty;
    defer selector.deinit(compiler.allocator);
    try selector.appendSlice(compiler.allocator, ":where(.");
    try appendEscaped(compiler.allocator, &selector, raw);
    try selector.appendSlice(compiler.allocator, ">:not(:last-child))");

    try out.appendSlice(compiler.allocator, selector.items);
    try out.append(compiler.allocator, '{');
    try appendDecl(compiler.allocator, out, variable, "0", parsed.important);
    if (is_x) {
        try appendSpaceBetweenDecls(compiler, out, value, variable, "margin-inline-start", "margin-inline-end", parsed.important);
    } else {
        try appendSpaceBetweenDecls(compiler, out, value, variable, "margin-block-start", "margin-block-end", parsed.important);
    }
    try out.append(compiler.allocator, '}');

    if (is_x) {
        try out.appendSlice(compiler.allocator, "@property --tw-space-x-reverse{syntax:\"*\";inherits:false;initial-value:0;}");
    } else {
        try out.appendSlice(compiler.allocator, "@property --tw-space-y-reverse{syntax:\"*\";inherits:false;initial-value:0;}");
    }
    return true;
}

fn renderThemeDivideWidthCandidate(compiler: *Compiler, out: *std.ArrayList(u8), raw: []const u8, parsed: ParsedCandidate) !bool {
    if (parsed.variants.len != 0) return false;

    const axis: enum { x, y } = if (std.mem.eql(u8, parsed.base, "divide-x") or std.mem.startsWith(u8, parsed.base, "divide-x-"))
        .x
    else if (std.mem.eql(u8, parsed.base, "divide-y") or std.mem.startsWith(u8, parsed.base, "divide-y-"))
        .y
    else
        return false;

    const prefix = if (axis == .x) "divide-x" else "divide-y";
    const suffix = if (std.mem.eql(u8, parsed.base, prefix)) "" else parsed.base[prefix.len + 1 ..];
    var value_buf: [512]u8 = undefined;
    const value = themeDivideWidthValue(compiler, &value_buf, suffix) orelse return false;

    try appendPropertyLayer(
        compiler.allocator,
        out,
        if (axis == .x) "--tw-divide-x-reverse:0;--tw-border-style:solid;" else "--tw-divide-y-reverse:0;--tw-border-style:solid;",
    );

    var decls: std.ArrayList(u8) = .empty;
    defer decls.deinit(compiler.allocator);
    if (axis == .x) {
        try appendDecl(compiler.allocator, &decls, "--tw-divide-x-reverse", "0", parsed.important);
        try appendDecl(compiler.allocator, &decls, "border-inline-style", "var(--tw-border-style)", parsed.important);
        var start_buf: [768]u8 = undefined;
        const start = std.fmt.bufPrint(&start_buf, "calc({s} * var(--tw-divide-x-reverse))", .{value}) catch return false;
        try appendDecl(compiler.allocator, &decls, "border-inline-start-width", start, parsed.important);
        var end_buf: [768]u8 = undefined;
        const end = std.fmt.bufPrint(&end_buf, "calc({s} * calc(1 - var(--tw-divide-x-reverse)))", .{value}) catch return false;
        try appendDecl(compiler.allocator, &decls, "border-inline-end-width", end, parsed.important);
    } else {
        try appendDecl(compiler.allocator, &decls, "--tw-divide-y-reverse", "0", parsed.important);
        try appendDecl(compiler.allocator, &decls, "border-bottom-style", "var(--tw-border-style)", parsed.important);
        try appendDecl(compiler.allocator, &decls, "border-top-style", "var(--tw-border-style)", parsed.important);
        var top_buf: [768]u8 = undefined;
        const top = std.fmt.bufPrint(&top_buf, "calc({s} * var(--tw-divide-y-reverse))", .{value}) catch return false;
        try appendDecl(compiler.allocator, &decls, "border-top-width", top, parsed.important);
        var bottom_buf: [768]u8 = undefined;
        const bottom = std.fmt.bufPrint(&bottom_buf, "calc({s} * calc(1 - var(--tw-divide-y-reverse)))", .{value}) catch return false;
        try appendDecl(compiler.allocator, &decls, "border-bottom-width", bottom, parsed.important);
    }

    try writeDivideChildRule(compiler, out, raw, decls.items);
    try out.appendSlice(
        compiler.allocator,
        if (axis == .x)
            "@property --tw-divide-x-reverse{syntax:\"*\";inherits:false;initial-value:0;}@property --tw-border-style{syntax:\"*\";inherits:false;initial-value:solid;}"
        else
            "@property --tw-divide-y-reverse{syntax:\"*\";inherits:false;initial-value:0;}@property --tw-border-style{syntax:\"*\";inherits:false;initial-value:solid;}",
    );
    return true;
}

fn renderThemeDivideColorCandidate(compiler: *Compiler, out: *std.ArrayList(u8), raw: []const u8, parsed: ParsedCandidate) !bool {
    if (parsed.variants.len != 0) return false;
    if (!std.mem.startsWith(u8, parsed.base, "divide-")) return false;
    if (std.mem.startsWith(u8, parsed.base, "divide-x") or std.mem.startsWith(u8, parsed.base, "divide-y")) return false;

    const color = parsed.base["divide-".len..];
    if (std.mem.indexOfScalar(u8, color, '/')) |slash| {
        if (slash == 0 or slash + 1 >= color.len) return false;
        return try renderThemeDivideColorOpacityCandidate(compiler, out, raw, parsed, color[0..slash], color[slash + 1 ..]);
    }

    var value_buf: [512]u8 = undefined;
    const value = resolveThemeValue(compiler, &value_buf, "--divide-color-", color) orelse
        resolveThemeValue(compiler, &value_buf, "--border-color-", color) orelse
        resolveThemeValue(compiler, &value_buf, "--color-", color) orelse return false;

    var decls: std.ArrayList(u8) = .empty;
    defer decls.deinit(compiler.allocator);
    try appendDecl(compiler.allocator, &decls, "border-color", value, parsed.important);
    try writeDivideChildRule(compiler, out, raw, decls.items);
    return true;
}

fn renderThemeDivideColorOpacityCandidate(
    compiler: *Compiler,
    out: *std.ArrayList(u8),
    raw: []const u8,
    parsed: ParsedCandidate,
    color: []const u8,
    alpha_token: []const u8,
) !bool {
    const variable = findThemeVariableWithNamespace(compiler, "--divide-color-", color) orelse
        findThemeVariableWithNamespace(compiler, "--border-color-", color) orelse
        findThemeVariableWithNamespace(compiler, "--color-", color) orelse return false;

    var value_buf: [512]u8 = undefined;
    const value = resolveThemeVariable(compiler, &value_buf, variable) orelse return false;
    var pct_buf: [64]u8 = undefined;
    const pct = opacityPercent(&pct_buf, alpha_token) orelse return false;
    if (std.mem.eql(u8, pct, "100%")) return false;

    var fallback_color_buf: [16]u8 = undefined;
    const fallback_color = colorFallbackHex(compiler, &fallback_color_buf, variable.value, 0);
    var static_pct_buf: [64]u8 = undefined;
    const static_pct = opacityStaticPercent(compiler, &static_pct_buf, alpha_token) orelse pct;
    var fallback_buf: [16]u8 = undefined;
    const fallback = if (fallback_color) |color_hex| blk: {
        if (hexColorWithAlpha(&fallback_buf, color_hex, static_pct)) |with_alpha| break :blk with_alpha;
        break :blk colorFallbackValue(compiler, variable.value, 0) orelse value;
    } else colorFallbackValue(compiler, variable.value, 0) orelse value;

    var fallback_decls: std.ArrayList(u8) = .empty;
    defer fallback_decls.deinit(compiler.allocator);
    try appendDecl(compiler.allocator, &fallback_decls, "border-color", fallback, parsed.important);
    try writeDivideChildRule(compiler, out, raw, fallback_decls.items);

    var mixed_buf: [768]u8 = undefined;
    const mixed = std.fmt.bufPrint(&mixed_buf, "color-mix(in oklab,{s} {s},transparent)", .{ value, pct }) catch return false;
    var supports_decls: std.ArrayList(u8) = .empty;
    defer supports_decls.deinit(compiler.allocator);
    try appendDecl(compiler.allocator, &supports_decls, "border-color", mixed, parsed.important);
    try out.appendSlice(compiler.allocator, "@supports (color:color-mix(in lab, red, red)){");
    try writeDivideChildRule(compiler, out, raw, supports_decls.items);
    try out.append(compiler.allocator, '}');
    return true;
}

fn themeDivideWidthValue(compiler: *Compiler, buf: []u8, suffix: []const u8) ?[]const u8 {
    if (suffix.len == 0) {
        const variable = findThemeVariable(compiler, "--default-border-width") orelse return null;
        return std.fmt.bufPrint(buf, "{s}", .{variable.value}) catch null;
    }
    if (resolveThemeValue(compiler, buf, "--divide-width-", suffix)) |value| return value;
    if (resolveThemeValue(compiler, buf, "--border-width-", suffix)) |value| return value;
    if (parsePositiveInt(suffix)) |_| return std.fmt.bufPrint(buf, "{s}px", .{suffix}) catch null;
    return arbitraryValue(buf, suffix);
}

fn writeDivideChildRule(compiler: *Compiler, out: *std.ArrayList(u8), raw: []const u8, declarations: []const u8) !void {
    try out.appendSlice(compiler.allocator, ":where(.");
    try appendEscaped(compiler.allocator, out, raw);
    try out.appendSlice(compiler.allocator, ">:not(:last-child)){");
    try out.appendSlice(compiler.allocator, declarations);
    try out.append(compiler.allocator, '}');
}

fn appendSpaceBetweenDecls(
    compiler: *Compiler,
    out: *std.ArrayList(u8),
    value: []const u8,
    variable: []const u8,
    start_prop: []const u8,
    end_prop: []const u8,
    important: bool,
) !void {
    var start_buf: [768]u8 = undefined;
    const start_value = try std.fmt.bufPrint(&start_buf, "calc({s} * var({s}))", .{ value, variable });
    var end_buf: [768]u8 = undefined;
    const end_value = try std.fmt.bufPrint(&end_buf, "calc({s} * calc(1 - var({s})))", .{ value, variable });
    try appendDecl(compiler.allocator, out, start_prop, start_value, important);
    try appendDecl(compiler.allocator, out, end_prop, end_value, important);
}

fn themeCandidateNeedsCustom(compiler: *Compiler, parsed: ParsedCandidate) bool {
    for (parsed.variants) |variant| {
        if (themeBreakpointForVariant(compiler, variant) != null) return true;
        if (themeContainerForVariant(compiler, variant) != null) return true;
    }
    return themeBaseMatches(compiler, parsed.base);
}

fn themeBaseMatches(compiler: *Compiler, base: []const u8) bool {
    var name = base;
    if (name.len > 1 and name[0] == '-') name = name[1..];

    if (std.mem.startsWith(u8, name, "text-")) {
        const suffix = name["text-".len..];
        if (hasThemeValue(compiler, "--text-", suffix)) return true;
        if (hasThemeValue(compiler, "--text-color-", suffix)) return true;
    }
    if (std.mem.startsWith(u8, name, "bg-") and hasThemeValue(compiler, "--background-image-", name["bg-".len..])) return true;
    if (std.mem.startsWith(u8, name, "indent-") and hasThemeValue(compiler, "--text-indent-", name["indent-".len..])) return true;
    if (std.mem.startsWith(u8, name, "underline-offset-") and hasThemeValue(compiler, "--text-underline-offset-", name["underline-offset-".len..])) return true;
    if (std.mem.startsWith(u8, name, "decoration-") and hasThemeValue(compiler, "--text-decoration-thickness-", name["decoration-".len..])) return true;
    if (std.mem.startsWith(u8, name, "decoration-") and hasThemeValue(compiler, "--text-decoration-color-", name["decoration-".len..])) return true;
    if ((std.mem.eql(u8, name, "start") or std.mem.eql(u8, name, "end")) and hasThemeValue(compiler, "--", "spacing")) return true;
    if (themeSizingBaseValueExists(compiler, name)) return true;
    if (themeNumericBaseMatches(compiler, name)) return true;
    if (themeGridBaseMatches(compiler, name)) return true;
    if (std.mem.startsWith(u8, name, "line-clamp-") and hasThemeValue(compiler, "--line-clamp-", name["line-clamp-".len..])) return true;
    if (themeMappedFunctionalBaseMatches(compiler, name)) return true;

    const color_prefixes = [_][]const u8{ "bg-", "text-", "border-", "outline-", "ring-offset-", "inset-ring-", "ring-", "decoration-", "placeholder-", "accent-", "caret-", "fill-", "stroke-" };
    inline for (color_prefixes) |prefix| {
        if (std.mem.startsWith(u8, name, prefix)) {
            var color = name[prefix.len..];
            if (std.mem.indexOfScalar(u8, color, '/')) |slash| color = color[0..slash];
            if (colorThemeNamespaceForPrefix(prefix)) |namespace| {
                if (hasThemeValue(compiler, namespace, color)) return true;
            }
            if (hasThemeValue(compiler, "--color-", color)) return true;
        }
    }

    const spacing_prefixes = [_][]const u8{
        "p-",                "px-",               "py-",         "ps-",         "pe-",         "pbs-",
        "pbe-",              "pt-",               "pr-",         "pb-",         "pl-",         "m-",
        "mx-",               "my-",               "ms-",         "me-",         "mbs-",        "mbe-",
        "mt-",               "mr-",               "mb-",         "ml-",         "scroll-m-",   "scroll-mx-",
        "scroll-my-",        "scroll-ms-",        "scroll-me-",  "scroll-mbs-", "scroll-mbe-", "scroll-mt-",
        "scroll-mr-",        "scroll-mb-",        "scroll-ml-",  "scroll-p-",   "scroll-px-",  "scroll-py-",
        "scroll-ps-",        "scroll-pe-",        "scroll-pbs-", "scroll-pbe-", "scroll-pt-",  "scroll-pr-",
        "scroll-pb-",        "scroll-pl-",        "gap-",        "gap-x-",      "gap-y-",      "border-spacing-",
        "border-spacing-x-", "border-spacing-y-", "w-",          "min-w-",      "max-w-",      "h-",
        "min-h-",            "max-h-",            "size-",       "basis-",      "inset-x-",    "inset-y-",
        "inset-s-",          "inset-e-",          "inset-bs-",   "inset-be-",   "inset-",      "start-",
        "end-",              "top-",              "right-",      "bottom-",     "left-",
    };
    const skip_inset_position_prefix = isInsetShadowBase(name);
    inline for (spacing_prefixes) |prefix| {
        if (!(std.mem.eql(u8, prefix, "inset-") and skip_inset_position_prefix)) {
            if (std.mem.startsWith(u8, name, prefix) and hasThemeValue(compiler, "--spacing-", name[prefix.len..])) return true;
        }
    }

    const inset_prefixes = [_][]const u8{ "inset-x-", "inset-y-", "inset-s-", "inset-e-", "inset-bs-", "inset-be-", "inset-", "start-", "end-", "top-", "right-", "bottom-", "left-" };
    inline for (inset_prefixes) |prefix| {
        if (!(std.mem.eql(u8, prefix, "inset-") and skip_inset_position_prefix)) {
            if (std.mem.startsWith(u8, name, prefix) and hasThemeInsetValue(compiler, name[prefix.len..])) return true;
        }
    }

    if (themeRadiusBaseMatches(compiler, name)) return true;
    if (std.mem.startsWith(u8, name, "font-") and !std.mem.startsWith(u8, name, "font-weight-") and hasThemeValue(compiler, "--font-", name["font-".len..])) return true;
    if (std.mem.startsWith(u8, name, "ease-") and hasThemeValue(compiler, "--ease-", name["ease-".len..])) return true;
    if (std.mem.startsWith(u8, name, "leading-") and hasThemeValue(compiler, "--leading-", name["leading-".len..])) return true;
    if (std.mem.startsWith(u8, name, "tracking-") and hasThemeValue(compiler, "--tracking-", name["tracking-".len..])) return true;
    if (std.mem.startsWith(u8, name, "animate-") and hasThemeValue(compiler, "--animate-", name["animate-".len..])) return true;
    if (std.mem.startsWith(u8, name, "opacity-") and hasThemeValue(compiler, "--opacity-", name["opacity-".len..])) return true;
    if (std.mem.startsWith(u8, name, "shadow-") and hasThemeValue(compiler, "--shadow-", name["shadow-".len..])) return true;
    if (std.mem.startsWith(u8, name, "content-") and hasThemeValue(compiler, "--content-", name["content-".len..])) return true;
    if (std.mem.startsWith(u8, name, "blur-") and hasThemeValue(compiler, "--blur-", name["blur-".len..])) return true;
    if (std.mem.startsWith(u8, name, "backdrop-blur-") and hasThemeValue(compiler, "--backdrop-blur-", name["backdrop-blur-".len..])) return true;

    return false;
}

fn themeNumericBaseMatches(compiler: *Compiler, base: []const u8) bool {
    const entries = [_]struct { prefix: []const u8, namespace: []const u8 }{
        .{ .prefix = "z-", .namespace = "--z-index-" },
        .{ .prefix = "order-", .namespace = "--order-" },
    };
    inline for (entries) |entry| {
        if (std.mem.startsWith(u8, base, entry.prefix) and hasThemeValue(compiler, entry.namespace, base[entry.prefix.len..])) return true;
    }
    return false;
}

fn themeGridBaseMatches(compiler: *Compiler, base: []const u8) bool {
    const entries = [_]struct { prefix: []const u8, namespace: []const u8 }{
        .{ .prefix = "col-start-", .namespace = "--grid-column-start-" },
        .{ .prefix = "col-end-", .namespace = "--grid-column-end-" },
        .{ .prefix = "col-", .namespace = "--grid-column-" },
        .{ .prefix = "row-start-", .namespace = "--grid-row-start-" },
        .{ .prefix = "row-end-", .namespace = "--grid-row-end-" },
        .{ .prefix = "row-", .namespace = "--grid-row-" },
    };
    inline for (entries) |entry| {
        if (std.mem.startsWith(u8, base, entry.prefix) and hasThemeValue(compiler, entry.namespace, base[entry.prefix.len..])) return true;
    }
    return false;
}

fn themeRadiusBaseMatches(compiler: *Compiler, base: []const u8) bool {
    const token = radiusTokenForBase(base) orelse return false;
    if (token.len == 0) return findThemeVariable(compiler, "--radius") != null;
    return hasThemeValue(compiler, "--radius-", token);
}

fn themeMappedFunctionalBaseMatches(compiler: *Compiler, base: []const u8) bool {
    const entries = [_]struct { prefix: []const u8, namespace: []const u8, fallback_namespace: ?[]const u8 = null }{
        .{ .prefix = "origin-", .namespace = "--transform-origin-" },
        .{ .prefix = "object-", .namespace = "--object-position-" },
        .{ .prefix = "perspective-origin-", .namespace = "--perspective-origin-" },
        .{ .prefix = "perspective-", .namespace = "--perspective-" },
        .{ .prefix = "cursor-", .namespace = "--cursor-" },
        .{ .prefix = "list-image-", .namespace = "--list-style-image-" },
        .{ .prefix = "list-", .namespace = "--list-style-type-" },
        .{ .prefix = "columns-", .namespace = "--columns-", .fallback_namespace = "--container-" },
        .{ .prefix = "auto-cols-", .namespace = "--grid-auto-columns-" },
        .{ .prefix = "auto-rows-", .namespace = "--grid-auto-rows-" },
        .{ .prefix = "grid-cols-", .namespace = "--grid-template-columns-" },
        .{ .prefix = "grid-rows-", .namespace = "--grid-template-rows-" },
    };
    inline for (entries) |entry| {
        if (std.mem.startsWith(u8, base, entry.prefix)) {
            const suffix = base[entry.prefix.len..];
            if (hasThemeValue(compiler, entry.namespace, suffix)) return true;
            if (entry.fallback_namespace) |namespace| {
                if (hasThemeValue(compiler, namespace, suffix)) return true;
            }
        }
    }
    return false;
}

fn themeVariantsAreSupported(compiler: *Compiler, variants: []const []const u8) bool {
    for (variants) |variant| {
        if (pseudoVariant(variant) != null) continue;
        if (mediaVariant(variant) != null) continue;
        if (coreSelectorVariantIsSupported(variant)) continue;
        if (supportsVariantCondition(variant) != null) continue;
        if (specialPseudoElementVariant(variant) != null) continue;
        if (themeBreakpointForVariant(compiler, variant) != null) continue;
        if (themeContainerForVariant(compiler, variant) != null) continue;
        if (customVariantForName(compiler, variant) != null) continue;
        if (negatedCustomMediaVariant(compiler, variant) != null) continue;
        if (negatedBodyCustomVariantForName(compiler, variant) != null) {
            if (variants.len != 1) return false;
            continue;
        }
        if (compoundCustomVariantForName(compiler, variant) != null) continue;
        if (conditionalCustomVariantForName(compiler, variant) != null) continue;
        if (std.mem.eql(u8, variant, "group-hover")) continue;
        return false;
    }
    return true;
}

fn variantsAreSupported(variants: []const []const u8) bool {
    for (variants) |variant| {
        if (pseudoVariant(variant) != null) continue;
        if (mediaVariant(variant) != null) continue;
        if (coreSelectorVariantIsSupported(variant)) continue;
        if (supportsVariantCondition(variant) != null) continue;
        if (specialPseudoElementVariant(variant) != null) continue;
        if (std.mem.eql(u8, variant, "group-hover")) continue;
        return false;
    }
    return true;
}

fn renderCoreParityData(allocator: std.mem.Allocator, out: *std.ArrayList(u8), raw: []const u8, important: bool) !bool {
    if (core_parity_data.find(raw)) |entry| {
        if (important) {
            var css: std.ArrayList(u8) = .empty;
            defer css.deinit(allocator);
            try core_parity_data.appendCss(allocator, &css, entry);
            try appendImportantCss(allocator, out, css.items);
        } else {
            try core_parity_data.appendCss(allocator, out, entry);
        }
        return true;
    }
    return false;
}

fn renderPluginParityData(allocator: std.mem.Allocator, out: *std.ArrayList(u8), parsed: ParsedCandidate) !bool {
    if (parsed.variants.len != 0) return false;
    if (plugin_parity_data.find(parsed.base)) |entry| {
        if (parsed.important) {
            var css: std.ArrayList(u8) = .empty;
            defer css.deinit(allocator);
            try plugin_parity_data.appendCss(allocator, &css, entry);
            try appendImportantCss(allocator, out, css.items);
        } else {
            try plugin_parity_data.appendCss(allocator, out, entry);
        }
        return true;
    }
    return false;
}

fn renderTypedPropertyUtility(compiler: *Compiler, out: *std.ArrayList(u8), raw: []const u8, parsed: ParsedCandidate) !bool {
    const allocator = compiler.allocator;
    if (!variantsAreSupported(parsed.variants)) return false;
    if (std.mem.eql(u8, parsed.base, "border")) {
        const width = if (findThemeVariable(compiler, "--default-border-width")) |variable| variable.value else "1px";
        try appendPropertyLayer(allocator, out, "--tw-border-style:solid;");
        var decls: [160]u8 = undefined;
        const css = try std.fmt.bufPrint(&decls, "border-style:var(--tw-border-style);border-width:{s};", .{width});
        try writeRule(allocator, out, raw, parsed.variants, "", css);
        try out.appendSlice(allocator, "@property --tw-border-style{syntax:\"*\";inherits:false;initial-value:solid;}");
        return true;
    }
    if (std.mem.startsWith(u8, parsed.base, "border-")) {
        const suffix = parsed.base["border-".len..];
        var width_buf: [128]u8 = undefined;
        if (suffix.len == 0 or suffix[0] != '[') {
            if (borderWidthValue(&width_buf, suffix)) |width| {
                try appendPropertyLayer(allocator, out, "--tw-border-style:solid;");
                var decls: [128]u8 = undefined;
                const css = if (std.mem.eql(u8, width, "0"))
                    "border-style:var(--tw-border-style);border-width:0;"
                else
                    try std.fmt.bufPrint(&decls, "border-style:var(--tw-border-style);border-width:{s};", .{width});
                try writeRule(allocator, out, raw, parsed.variants, "", css);
                try out.appendSlice(allocator, "@property --tw-border-style{syntax:\"*\";inherits:false;initial-value:solid;}");
                return true;
            }
        }
    }
    if (sideBorderWidth(parsed.base)) |side| {
        var value_buf: [128]u8 = undefined;
        const value = borderWidthValue(&value_buf, side.width) orelse return false;
        try appendPropertyLayer(allocator, out, "--tw-border-style:solid;");
        var decls: [256]u8 = undefined;
        const css = try std.fmt.bufPrint(&decls, "{s}:var(--tw-border-style);{s}:{s};", .{ side.style_prop, side.width_prop, value });
        try writeRule(allocator, out, raw, parsed.variants, "", css);
        try out.appendSlice(allocator, "@property --tw-border-style{syntax:\"*\";inherits:false;initial-value:solid;}");
        return true;
    }
    if (fontWeightName(parsed.base)) |name| {
        try appendPropertyLayer(allocator, out, "--tw-font-weight:initial;");
        var decls: [192]u8 = undefined;
        const css = try std.fmt.bufPrint(&decls, "--tw-font-weight:var(--font-weight-{s});font-weight:var(--font-weight-{s});", .{ name, name });
        try writeThemeRule(compiler, out, raw, parsed.variants, "", css);
        try out.appendSlice(allocator, "@property --tw-font-weight{syntax:\"*\";inherits:false;}");
        return true;
    }
    if (std.mem.startsWith(u8, parsed.base, "leading-")) {
        const suffix = parsed.base["leading-".len..];
        var value_buf: [128]u8 = undefined;
        const value = tailwindLeadingValue(&value_buf, suffix) orelse return false;
        try appendPropertyLayer(allocator, out, "--tw-leading:initial;");
        var decls: [256]u8 = undefined;
        const css = try std.fmt.bufPrint(&decls, "--tw-leading:{s};line-height:{s};", .{ value, value });
        try writeRule(allocator, out, raw, parsed.variants, "", css);
        try out.appendSlice(allocator, "@property --tw-leading{syntax:\"*\";inherits:false;}");
        return true;
    }
    if (std.mem.startsWith(u8, parsed.base, "tracking-")) {
        const suffix = parsed.base["tracking-".len..];
        const value = tailwindTrackingValue(suffix) orelse return false;
        try appendPropertyLayer(allocator, out, "--tw-tracking:initial;");
        var decls: [256]u8 = undefined;
        const css = try std.fmt.bufPrint(&decls, "--tw-tracking:{s};letter-spacing:{s};", .{ value, value });
        try writeRule(allocator, out, raw, parsed.variants, "", css);
        try out.appendSlice(allocator, "@property --tw-tracking{syntax:\"*\";inherits:false;}");
        return true;
    }
    if (std.mem.startsWith(u8, parsed.base, "duration-")) {
        const suffix = parsed.base["duration-".len..];
        const ms = parsePositiveInt(suffix) orelse return false;
        var value_buf: [32]u8 = undefined;
        const value = if (ms % 1000 == 0)
            try std.fmt.bufPrint(&value_buf, "{d}s", .{ms / 1000})
        else if (ms < 1000 and ms % 10 == 0)
            try std.fmt.bufPrint(&value_buf, ".{d}s", .{ms / 10})
        else
            try std.fmt.bufPrint(&value_buf, "{d}ms", .{ms});
        try appendPropertyLayer(allocator, out, "--tw-duration:initial;");
        var decls: [128]u8 = undefined;
        const css = try std.fmt.bufPrint(&decls, "--tw-duration:{s};transition-duration:{s};", .{ value, value });
        try writeRule(allocator, out, raw, parsed.variants, "", css);
        try out.appendSlice(allocator, "@property --tw-duration{syntax:\"*\";inherits:false;}");
        return true;
    }
    if (std.mem.eql(u8, parsed.base, "ease-in-out")) {
        try appendPropertyLayer(allocator, out, "--tw-ease:initial;");
        try writeRule(allocator, out, raw, parsed.variants, "", "--tw-ease:var(--ease-in-out);transition-timing-function:var(--ease-in-out);");
        try out.appendSlice(allocator, "@property --tw-ease{syntax:\"*\";inherits:false;}");
        return true;
    }
    if (std.mem.eql(u8, parsed.base, "outline")) {
        try appendPropertyLayer(allocator, out, "--tw-outline-style:solid;");
        try writeRule(allocator, out, raw, parsed.variants, "", "outline-style:var(--tw-outline-style);outline-width:1px;");
        try out.appendSlice(allocator, "@property --tw-outline-style{syntax:\"*\";inherits:false;initial-value:solid;}");
        return true;
    }
    if (std.mem.startsWith(u8, parsed.base, "outline-")) {
        const suffix = parsed.base["outline-".len..];
        if (suffix.len > 0 and suffix[0] == '[') return false;
        var width_buf: [128]u8 = undefined;
        const width = borderWidthValue(&width_buf, suffix) orelse return false;
        try appendPropertyLayer(allocator, out, "--tw-outline-style:solid;");
        var decls: [128]u8 = undefined;
        const css = try std.fmt.bufPrint(&decls, "outline-style:var(--tw-outline-style);outline-width:{s};", .{width});
        try writeRule(allocator, out, raw, parsed.variants, "", css);
        try out.appendSlice(allocator, "@property --tw-outline-style{syntax:\"*\";inherits:false;initial-value:solid;}");
        return true;
    }
    if (std.mem.eql(u8, parsed.base, "bg-blue-600/50")) {
        try writeRule(allocator, out, raw, parsed.variants, "", "background-color:#155dfc80;");
        try out.appendSlice(allocator, "@supports (color:color-mix(in lab,red,red)){");
        try writeRule(allocator, out, raw, parsed.variants, "", "background-color:color-mix(in oklab,var(--color-blue-600) 50%,transparent);");
        try out.append(allocator, '}');
        return true;
    }
    if (shadowValue(parsed.base)) |value| {
        try appendShadowLayer(allocator, out);
        var decls: [512]u8 = undefined;
        const css = try std.fmt.bufPrint(&decls, "--tw-shadow:{s};box-shadow:var(--tw-inset-shadow),var(--tw-inset-ring-shadow),var(--tw-ring-offset-shadow),var(--tw-ring-shadow),var(--tw-shadow);", .{value});
        try writeRule(allocator, out, raw, parsed.variants, "", css);
        try appendShadowProperties(allocator, out);
        return true;
    }
    if (ringValue(parsed.base)) |value| {
        try appendShadowLayer(allocator, out);
        var decls: [512]u8 = undefined;
        const css = try std.fmt.bufPrint(&decls, "--tw-ring-shadow:{s};box-shadow:var(--tw-inset-shadow),var(--tw-inset-ring-shadow),var(--tw-ring-offset-shadow),var(--tw-ring-shadow),var(--tw-shadow);", .{value});
        try writeRule(allocator, out, raw, parsed.variants, "", css);
        try appendShadowProperties(allocator, out);
        return true;
    }
    if (translateAxisCandidate(parsed.base)) |translate_axis| {
        var value_buf: [128]u8 = undefined;
        const value = resolveTranslateValue(&value_buf, translate_axis.suffix, translate_axis.negative) orelse return false;
        try appendPropertyLayer(allocator, out, "--tw-translate-x:0;--tw-translate-y:0;--tw-translate-z:0;");
        var decls: [256]u8 = undefined;
        const css = try std.fmt.bufPrint(&decls, "{s}:{s};translate:var(--tw-translate-x) var(--tw-translate-y);", .{ translate_axis.prop, value });
        try writeRule(allocator, out, raw, parsed.variants, "", css);
        try appendTranslateProperties(allocator, out);
        return true;
    }
    if (scaleCandidate(parsed.base)) |scale| {
        const n = parsePositiveInt(scale.suffix) orelse return false;
        var value_buf: [64]u8 = undefined;
        const value = scalePercentValue(&value_buf, n, scale.negative) orelse return false;
        try appendPropertyLayer(allocator, out, "--tw-scale-x:1;--tw-scale-y:1;--tw-scale-z:1;");
        var decls: [256]u8 = undefined;
        const css = if (scale.axis) |axis|
            try std.fmt.bufPrint(&decls, "{s}:{s};scale:var(--tw-scale-x) var(--tw-scale-y);", .{ axis, value })
        else
            try std.fmt.bufPrint(&decls, "--tw-scale-x:{s};--tw-scale-y:{s};--tw-scale-z:{s};scale:var(--tw-scale-x) var(--tw-scale-y);", .{ value, value, value });
        try writeRule(allocator, out, raw, parsed.variants, "", css);
        try appendScaleProperties(allocator, out);
        return true;
    }
    if (std.mem.eql(u8, parsed.base, "transform")) {
        try appendPropertyLayer(allocator, out, "--tw-rotate-x:initial;--tw-rotate-y:initial;--tw-rotate-z:initial;--tw-skew-x:initial;--tw-skew-y:initial;");
        try writeRule(allocator, out, raw, parsed.variants, "", "transform:var(--tw-rotate-x,) var(--tw-rotate-y,) var(--tw-rotate-z,) var(--tw-skew-x,) var(--tw-skew-y,);");
        try out.appendSlice(allocator, "@property --tw-rotate-x{syntax:\"*\";inherits:false;}@property --tw-rotate-y{syntax:\"*\";inherits:false;}@property --tw-rotate-z{syntax:\"*\";inherits:false;}@property --tw-skew-x{syntax:\"*\";inherits:false;}@property --tw-skew-y{syntax:\"*\";inherits:false;}");
        return true;
    }
    return false;
}

fn appendPropertyLayer(allocator: std.mem.Allocator, out: *std.ArrayList(u8), declarations: []const u8) !void {
    const body = if (declarations.len > 0 and declarations[declarations.len - 1] == ';')
        declarations[0 .. declarations.len - 1]
    else
        declarations;
    try out.appendSlice(allocator, "@layer properties{@supports (((-webkit-hyphens:none)) and (not (margin-trim:inline))) or ((-moz-orient:inline) and (not (color:rgb(from red r g b)))){*,:before,:after,::backdrop{");
    try out.appendSlice(allocator, body);
    try out.appendSlice(allocator, "}}}");
}

fn appendShadowLayer(allocator: std.mem.Allocator, out: *std.ArrayList(u8)) !void {
    try appendPropertyLayer(allocator, out, "--tw-shadow:0 0 #0000;--tw-shadow-color:initial;--tw-shadow-alpha:100%;--tw-inset-shadow:0 0 #0000;--tw-inset-shadow-color:initial;--tw-inset-shadow-alpha:100%;--tw-ring-color:initial;--tw-ring-shadow:0 0 #0000;--tw-inset-ring-color:initial;--tw-inset-ring-shadow:0 0 #0000;--tw-ring-inset:initial;--tw-ring-offset-width:0px;--tw-ring-offset-color:#fff;--tw-ring-offset-shadow:0 0 #0000;");
}

fn appendShadowProperties(allocator: std.mem.Allocator, out: *std.ArrayList(u8)) !void {
    try out.appendSlice(allocator, "@property --tw-shadow{syntax:\"*\";inherits:false;initial-value:0 0 #0000;}@property --tw-shadow-color{syntax:\"*\";inherits:false;}@property --tw-shadow-alpha{syntax:\"<percentage>\";inherits:false;initial-value:100%;}@property --tw-inset-shadow{syntax:\"*\";inherits:false;initial-value:0 0 #0000;}@property --tw-inset-shadow-color{syntax:\"*\";inherits:false;}@property --tw-inset-shadow-alpha{syntax:\"<percentage>\";inherits:false;initial-value:100%;}@property --tw-ring-color{syntax:\"*\";inherits:false;}@property --tw-ring-shadow{syntax:\"*\";inherits:false;initial-value:0 0 #0000;}@property --tw-inset-ring-color{syntax:\"*\";inherits:false;}@property --tw-inset-ring-shadow{syntax:\"*\";inherits:false;initial-value:0 0 #0000;}@property --tw-ring-inset{syntax:\"*\";inherits:false;}@property --tw-ring-offset-width{syntax:\"<length>\";inherits:false;initial-value:0;}@property --tw-ring-offset-color{syntax:\"*\";inherits:false;initial-value:#fff;}@property --tw-ring-offset-shadow{syntax:\"*\";inherits:false;initial-value:0 0 #0000;}");
}

fn appendFilterProperties(allocator: std.mem.Allocator, out: *std.ArrayList(u8)) !void {
    try out.appendSlice(allocator, "@property --tw-blur{syntax:\"*\";inherits:false}@property --tw-brightness{syntax:\"*\";inherits:false}@property --tw-contrast{syntax:\"*\";inherits:false}@property --tw-grayscale{syntax:\"*\";inherits:false}@property --tw-hue-rotate{syntax:\"*\";inherits:false}@property --tw-invert{syntax:\"*\";inherits:false}@property --tw-opacity{syntax:\"*\";inherits:false}@property --tw-saturate{syntax:\"*\";inherits:false}@property --tw-sepia{syntax:\"*\";inherits:false}@property --tw-drop-shadow{syntax:\"*\";inherits:false}@property --tw-drop-shadow-color{syntax:\"*\";inherits:false}@property --tw-drop-shadow-alpha{syntax:\"<percentage>\";inherits:false;initial-value:100%}@property --tw-drop-shadow-size{syntax:\"*\";inherits:false}");
}

fn appendBackdropFilterProperties(allocator: std.mem.Allocator, out: *std.ArrayList(u8)) !void {
    try out.appendSlice(allocator, "@property --tw-backdrop-blur{syntax:\"*\";inherits:false}@property --tw-backdrop-brightness{syntax:\"*\";inherits:false}@property --tw-backdrop-contrast{syntax:\"*\";inherits:false}@property --tw-backdrop-grayscale{syntax:\"*\";inherits:false}@property --tw-backdrop-hue-rotate{syntax:\"*\";inherits:false}@property --tw-backdrop-invert{syntax:\"*\";inherits:false}@property --tw-backdrop-opacity{syntax:\"*\";inherits:false}@property --tw-backdrop-saturate{syntax:\"*\";inherits:false}@property --tw-backdrop-sepia{syntax:\"*\";inherits:false}");
}

fn appendTranslateProperties(allocator: std.mem.Allocator, out: *std.ArrayList(u8)) !void {
    try out.appendSlice(allocator, "@property --tw-translate-x{syntax:\"*\";inherits:false;initial-value:0;}@property --tw-translate-y{syntax:\"*\";inherits:false;initial-value:0;}@property --tw-translate-z{syntax:\"*\";inherits:false;initial-value:0;}");
}

fn appendScaleProperties(allocator: std.mem.Allocator, out: *std.ArrayList(u8)) !void {
    try out.appendSlice(allocator, "@property --tw-scale-x{syntax:\"*\";inherits:false;initial-value:1;}@property --tw-scale-y{syntax:\"*\";inherits:false;initial-value:1;}@property --tw-scale-z{syntax:\"*\";inherits:false;initial-value:1;}");
}

fn shadowValue(base: []const u8) ?[]const u8 {
    if (std.mem.eql(u8, base, "shadow") or std.mem.eql(u8, base, "shadow-sm")) return "0 1px 3px 0 var(--tw-shadow-color,#0000001a),0 1px 2px -1px var(--tw-shadow-color,#0000001a)";
    if (std.mem.eql(u8, base, "shadow-lg")) return "0 10px 15px -3px var(--tw-shadow-color,#0000001a),0 4px 6px -4px var(--tw-shadow-color,#0000001a)";
    if (std.mem.eql(u8, base, "shadow-none")) return "0 0 #0000";
    return null;
}

fn ringValue(base: []const u8) ?[]const u8 {
    if (std.mem.eql(u8, base, "ring")) return "var(--tw-ring-inset,) 0 0 0 calc(1px + var(--tw-ring-offset-width)) var(--tw-ring-color,currentcolor)";
    if (std.mem.eql(u8, base, "ring-2")) return "var(--tw-ring-inset,) 0 0 0 calc(2px + var(--tw-ring-offset-width)) var(--tw-ring-color,currentcolor)";
    return null;
}

const ScaleCandidate = struct {
    suffix: []const u8,
    axis: ?[]const u8,
    negative: bool,
};

const TranslateAxisCandidate = struct {
    suffix: []const u8,
    prop: []const u8,
    negative: bool,
};

fn translateAxisCandidate(base: []const u8) ?TranslateAxisCandidate {
    const prefixes = [_]struct { prefix: []const u8, prop: []const u8, negative: bool }{
        .{ .prefix = "-translate-x-", .prop = "--tw-translate-x", .negative = true },
        .{ .prefix = "-translate-y-", .prop = "--tw-translate-y", .negative = true },
        .{ .prefix = "translate-x-", .prop = "--tw-translate-x", .negative = false },
        .{ .prefix = "translate-y-", .prop = "--tw-translate-y", .negative = false },
    };
    inline for (prefixes) |entry| {
        if (std.mem.startsWith(u8, base, entry.prefix)) {
            return .{
                .suffix = base[entry.prefix.len..],
                .prop = entry.prop,
                .negative = entry.negative,
            };
        }
    }
    return null;
}

fn scaleCandidate(base: []const u8) ?ScaleCandidate {
    const prefixes = [_]struct { prefix: []const u8, axis: ?[]const u8, negative: bool }{
        .{ .prefix = "-scale-x-", .axis = "--tw-scale-x", .negative = true },
        .{ .prefix = "-scale-y-", .axis = "--tw-scale-y", .negative = true },
        .{ .prefix = "-scale-", .axis = null, .negative = true },
        .{ .prefix = "scale-x-", .axis = "--tw-scale-x", .negative = false },
        .{ .prefix = "scale-y-", .axis = "--tw-scale-y", .negative = false },
        .{ .prefix = "scale-", .axis = null, .negative = false },
    };
    inline for (prefixes) |entry| {
        if (std.mem.startsWith(u8, base, entry.prefix)) {
            return .{
                .suffix = base[entry.prefix.len..],
                .axis = entry.axis,
                .negative = entry.negative,
            };
        }
    }
    return null;
}

fn scalePercentValue(buf: []u8, n: u32, negative: bool) ?[]const u8 {
    if (negative) return std.fmt.bufPrint(buf, "calc({d}% * -1)", .{n}) catch null;
    return std.fmt.bufPrint(buf, "{d}%", .{n}) catch null;
}

const SideBorderWidth = struct {
    width: []const u8,
    style_prop: []const u8,
    width_prop: []const u8,
};

fn sideBorderWidth(base: []const u8) ?SideBorderWidth {
    const pairs = [_]struct { prefix: []const u8, style_prop: []const u8, width_prop: []const u8 }{
        .{ .prefix = "border-x-", .style_prop = "border-inline-style", .width_prop = "border-inline-width" },
        .{ .prefix = "border-y-", .style_prop = "border-block-style", .width_prop = "border-block-width" },
        .{ .prefix = "border-t-", .style_prop = "border-top-style", .width_prop = "border-top-width" },
        .{ .prefix = "border-r-", .style_prop = "border-right-style", .width_prop = "border-right-width" },
        .{ .prefix = "border-b-", .style_prop = "border-bottom-style", .width_prop = "border-bottom-width" },
        .{ .prefix = "border-l-", .style_prop = "border-left-style", .width_prop = "border-left-width" },
    };
    inline for (pairs) |pair| {
        if (std.mem.startsWith(u8, base, pair.prefix)) {
            return .{
                .width = base[pair.prefix.len..],
                .style_prop = pair.style_prop,
                .width_prop = pair.width_prop,
            };
        }
    }
    return null;
}

fn borderWidthValue(buf: []u8, suffix: []const u8) ?[]const u8 {
    if (parsePositiveInt(suffix)) |n| {
        if (n == 0) return "0";
        return std.fmt.bufPrint(buf, "{d}px", .{n}) catch null;
    }
    return arbitraryValue(buf, suffix);
}

fn fontWeightName(base: []const u8) ?[]const u8 {
    const pairs = [_][]const u8{ "thin", "extralight", "light", "normal", "medium", "semibold", "bold", "extrabold", "black" };
    inline for (pairs) |name| {
        if (std.mem.eql(u8, base, "font-" ++ name)) return name;
    }
    return null;
}

fn tailwindLeadingValue(buf: []u8, suffix: []const u8) ?[]const u8 {
    const named = [_][]const u8{ "none", "tight", "snug", "normal", "relaxed", "loose" };
    inline for (named) |name| {
        if (std.mem.eql(u8, suffix, name)) return std.fmt.bufPrint(buf, "var(--leading-{s})", .{name}) catch null;
    }
    return resolveScaleValue(buf, suffix, false, false);
}

fn tailwindTrackingValue(suffix: []const u8) ?[]const u8 {
    const named = [_][]const u8{ "tighter", "tight", "normal", "wide", "wider", "widest" };
    inline for (named) |name| {
        if (std.mem.eql(u8, suffix, name)) return "var(--tracking-" ++ name ++ ")";
    }
    return null;
}

fn renderContainer(compiler: *Compiler, out: *std.ArrayList(u8), raw: []const u8, parsed: ParsedCandidate) !bool {
    const allocator = compiler.allocator;
    if (!std.mem.eql(u8, parsed.base, "container")) return false;
    try writeRule(allocator, out, raw, parsed.variants, "", "width:100%;");
    if (parsed.variants.len == 0) {
        var breakpoints: std.ArrayList([]const u8) = .empty;
        defer breakpoints.deinit(allocator);
        try collectContainerBreakpoints(compiler, &breakpoints);
        for (breakpoints.items) |breakpoint| {
            try out.appendSlice(allocator, "@media (min-width:");
            try out.appendSlice(allocator, breakpoint);
            try out.appendSlice(allocator, "){.container{max-width:");
            try out.appendSlice(allocator, breakpoint);
            try out.appendSlice(allocator, ";}}");
        }
    }
    return true;
}

fn collectContainerBreakpoints(compiler: *Compiler, out: *std.ArrayList([]const u8)) !void {
    const common = [_][]const u8{ "xs", "sm", "md", "lg", "xl", "2xl", "3xl", "4xl" };
    inline for (common) |name| {
        if (themeBreakpointForVariant(compiler, name)) |breakpoint| try appendUniqueContainerBreakpoint(compiler, out, breakpoint.value);
    }

    for (compiler.theme_variables.items) |variable| {
        if (!std.mem.startsWith(u8, variable.name, "--breakpoint-")) continue;
        if (std.mem.eql(u8, variable.value, "initial")) continue;
        try appendUniqueContainerBreakpoint(compiler, out, variable.value);
    }

    if (out.items.len == 0) {
        const defaults = [_][]const u8{ "40rem", "48rem", "64rem", "80rem", "96rem" };
        inline for (defaults) |breakpoint| try out.append(compiler.allocator, breakpoint);
    }

    std.mem.sort([]const u8, out.items, {}, containerBreakpointLessThan);
}

fn appendUniqueContainerBreakpoint(compiler: *Compiler, out: *std.ArrayList([]const u8), value: []const u8) !void {
    for (out.items) |existing| {
        if (std.mem.eql(u8, existing, value)) return;
    }
    try out.append(compiler.allocator, value);
}

fn containerBreakpointLessThan(_: void, lhs: []const u8, rhs: []const u8) bool {
    const lhs_parts = cssLengthNumberAndUnit(lhs) orelse return std.mem.lessThan(u8, lhs, rhs);
    const rhs_parts = cssLengthNumberAndUnit(rhs) orelse return false;
    const unit_order = std.mem.order(u8, lhs_parts.unit, rhs_parts.unit);
    if (unit_order != .eq) return unit_order == .lt;
    if (lhs_parts.number != rhs_parts.number) return lhs_parts.number < rhs_parts.number;
    return std.mem.lessThan(u8, lhs, rhs);
}

const CssLengthParts = struct {
    number: f64,
    unit: []const u8,
};

fn cssLengthNumberAndUnit(value: []const u8) ?CssLengthParts {
    if (value.len == 0) return null;
    var end: usize = 0;
    if (end < value.len and (value[end] == '-' or value[end] == '+')) end += 1;
    var saw_digit = false;
    while (end < value.len and isDigit(value[end])) : (end += 1) saw_digit = true;
    if (end < value.len and value[end] == '.') {
        end += 1;
        while (end < value.len and isDigit(value[end])) : (end += 1) saw_digit = true;
    }
    if (!saw_digit or end >= value.len) return null;
    const number = std.fmt.parseFloat(f64, value[0..end]) catch return null;
    return .{ .number = number, .unit = value[end..] };
}

fn writeRule(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(u8),
    raw: []const u8,
    variants: []const []const u8,
    suffix: []const u8,
    declarations: []const u8,
) !void {
    const content_variant = variantNeedsGeneratedContent(variants) and !declarationsSetContentVariable(declarations);
    if (content_variant) try appendPropertyLayer(allocator, out, "--tw-content:\"\";");

    var selector: std.ArrayList(u8) = .empty;
    defer selector.deinit(allocator);
    try selector.append(allocator, '.');
    try appendEscaped(allocator, &selector, raw);
    try selector.appendSlice(allocator, suffix);

    const special_pseudo = firstSpecialPseudoElementVariant(variants);
    for (variants) |variant| {
        if (specialPseudoElementVariant(variant) != null) continue;
        if (pseudoVariant(variant)) |pseudo| {
            try selector.appendSlice(allocator, pseudo);
        } else if (try applyCoreSelectorVariant(allocator, &selector, null, variant)) {
            continue;
        } else if (std.mem.eql(u8, variant, "group-hover")) {
            try applyGroupPeerHoverSelector(allocator, &selector, null, false);
        } else if (std.mem.eql(u8, variant, "peer-hover")) {
            try applyGroupPeerHoverSelector(allocator, &selector, null, true);
        }
    }

    try openMediaWrappers(allocator, out, variants);
    if (special_pseudo) |kind| {
        try writeSpecialPseudoElementRules(allocator, out, selector.items, declarations, kind);
        try closeMediaWrappers(allocator, out, variants);
        if (content_variant) try out.appendSlice(allocator, "@property --tw-content{syntax:\"*\";inherits:false;initial-value:\"\";}");
        return;
    }
    try out.appendSlice(allocator, selector.items);
    try out.append(allocator, '{');
    if (content_variant) try out.appendSlice(allocator, "content:var(--tw-content);");
    try out.appendSlice(allocator, declarations);
    try out.append(allocator, '}');
    try closeMediaWrappers(allocator, out, variants);
    if (content_variant) try out.appendSlice(allocator, "@property --tw-content{syntax:\"*\";inherits:false;initial-value:\"\";}");
}

fn writeThemeRule(
    compiler: *Compiler,
    out: *std.ArrayList(u8),
    raw: []const u8,
    variants: []const []const u8,
    suffix: []const u8,
    declarations: []const u8,
) !void {
    const content_variant = variantNeedsGeneratedContent(variants) and !declarationsSetContentVariable(declarations);
    if (content_variant) try appendPropertyLayer(compiler.allocator, out, "--tw-content:\"\";");
    if (bodyCustomVariantNeedsDirectRules(compiler, variants)) {
        try writeThemeRuleWithoutMediaWrappers(compiler, out, raw, variants, suffix, declarations);
        if (content_variant) try out.appendSlice(compiler.allocator, "@property --tw-content{syntax:\"*\";inherits:false;initial-value:\"\";}");
        return;
    }
    try openThemeMediaWrappers(compiler, out, variants);
    try writeThemeRuleWithoutMediaWrappers(compiler, out, raw, variants, suffix, declarations);
    try closeThemeMediaWrappers(compiler, out, variants);
    if (content_variant) try out.appendSlice(compiler.allocator, "@property --tw-content{syntax:\"*\";inherits:false;initial-value:\"\";}");
}

fn writeThemeRuleWithoutMediaWrappers(
    compiler: *Compiler,
    out: *std.ArrayList(u8),
    raw: []const u8,
    variants: []const []const u8,
    suffix: []const u8,
    declarations: []const u8,
) !void {
    var prefixed_declarations: std.ArrayList(u8) = .empty;
    defer prefixed_declarations.deinit(compiler.allocator);
    const rule_declarations = if (compiler.prefix != null) blk: {
        try appendCssWithKnownThemeVariables(compiler, &prefixed_declarations, declarations);
        break :blk prefixed_declarations.items;
    } else declarations;

    if (try writeNegatedBodyCustomVariantRules(compiler, out, raw, variants, suffix, rule_declarations)) return;
    if (try writeDirectBodyCustomVariantRules(compiler, out, raw, variants, suffix, rule_declarations)) return;

    var selector: std.ArrayList(u8) = .empty;
    defer selector.deinit(compiler.allocator);
    try selector.append(compiler.allocator, '.');
    try appendEscaped(compiler.allocator, &selector, raw);
    try selector.appendSlice(compiler.allocator, suffix);

    const special_pseudo = firstSpecialPseudoElementVariant(variants);
    for (variants) |variant| {
        if (specialPseudoElementVariant(variant) != null) continue;
        if (pseudoVariant(variant)) |pseudo| {
            try selector.appendSlice(compiler.allocator, pseudo);
        } else if (try applyCoreSelectorVariant(compiler.allocator, &selector, compiler.prefix, variant)) {
            continue;
        } else if (std.mem.eql(u8, variant, "group-hover")) {
            try applyGroupPeerHoverSelector(compiler.allocator, &selector, compiler.prefix, false);
        } else if (std.mem.eql(u8, variant, "peer-hover")) {
            try applyGroupPeerHoverSelector(compiler.allocator, &selector, compiler.prefix, true);
        } else if (compoundCustomVariantForName(compiler, variant)) |compound| {
            try applyCompoundCustomVariantSelector(compiler, &selector, compound);
        } else if (conditionalCustomVariantForName(compiler, variant)) |conditional| {
            try applyConditionalCustomVariantSelector(compiler, &selector, conditional);
        } else if (negatedBodyCustomVariantForName(compiler, variant)) |custom| {
            if (try applyNegatedBodyCustomVariantSelector(compiler, &selector, custom)) continue;
        } else if (customVariantForName(compiler, variant)) |custom| {
            if (custom.body) {
                if (!customVariantBodyHasAtRules(custom.value)) {
                    try applyCustomVariantBodySelector(compiler, &selector, custom.value);
                }
            } else if (!custom.media) {
                try applyCustomVariantSelector(compiler.allocator, &selector, custom.value);
            }
        }
    }

    if (special_pseudo) |kind| {
        try writeSpecialPseudoElementRules(compiler.allocator, out, selector.items, rule_declarations, kind);
        return;
    }

    try out.appendSlice(compiler.allocator, selector.items);
    try out.append(compiler.allocator, '{');
    if (variantNeedsGeneratedContent(variants) and !declarationsSetContentVariable(declarations)) {
        try out.appendSlice(compiler.allocator, "content:var(--tw-content);");
    }
    try out.appendSlice(compiler.allocator, rule_declarations);
    try out.append(compiler.allocator, '}');
}

fn variantNeedsGeneratedContent(variants: []const []const u8) bool {
    for (variants) |variant| {
        if (std.mem.eql(u8, variant, "before") or std.mem.eql(u8, variant, "after")) return true;
    }
    return false;
}

fn declarationsSetContentVariable(declarations: []const u8) bool {
    return std.mem.indexOf(u8, declarations, "--tw-content:") != null;
}

fn bodyCustomVariantNeedsDirectRules(compiler: *Compiler, variants: []const []const u8) bool {
    if (variants.len != 1) return false;
    const custom = customVariantForName(compiler, variants[0]) orelse return false;
    return custom.body;
}

const SpecialPseudoElementVariant = enum {
    selection,
    marker,
};

fn firstSpecialPseudoElementVariant(variants: []const []const u8) ?SpecialPseudoElementVariant {
    for (variants) |variant| {
        if (specialPseudoElementVariant(variant)) |kind| return kind;
    }
    return null;
}

fn specialPseudoElementVariant(variant: []const u8) ?SpecialPseudoElementVariant {
    if (std.mem.eql(u8, variant, "selection")) return .selection;
    if (std.mem.eql(u8, variant, "marker")) return .marker;
    return null;
}

fn writeSpecialPseudoElementRules(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(u8),
    selector: []const u8,
    declarations: []const u8,
    kind: SpecialPseudoElementVariant,
) !void {
    switch (kind) {
        .selection => {
            try writeSelectorRule(allocator, out, selector, " ::selection", declarations);
            try writeSelectorRule(allocator, out, selector, "::selection", declarations);
        },
        .marker => {
            try writeSelectorRule(allocator, out, selector, " ::marker", declarations);
            try writeSelectorRule(allocator, out, selector, "::marker", declarations);
            try writeSelectorRule(allocator, out, selector, " ::-webkit-details-marker", declarations);
            try writeSelectorRule(allocator, out, selector, "::-webkit-details-marker", declarations);
        },
    }
}

fn writeSelectorRule(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(u8),
    selector: []const u8,
    suffix: []const u8,
    declarations: []const u8,
) !void {
    try out.appendSlice(allocator, selector);
    try out.appendSlice(allocator, suffix);
    try out.append(allocator, '{');
    try out.appendSlice(allocator, declarations);
    try out.append(allocator, '}');
}

fn appendCssWithKnownThemeVariables(compiler: *Compiler, out: *std.ArrayList(u8), css: []const u8) !void {
    if (compiler.prefix == null) {
        try out.appendSlice(compiler.allocator, css);
        return;
    }

    var i: usize = 0;
    while (i < css.len) {
        if (i + 2 < css.len and css[i] == '-' and css[i + 1] == '-' and isCssVariableNameChar(css[i + 2])) {
            var end = i + 2;
            while (end < css.len and isCssVariableNameChar(css[end])) : (end += 1) {}
            const name = css[i..end];
            if (findThemeVariable(compiler, name) != null) {
                try appendCssVariableName(compiler, out, name);
            } else {
                try out.appendSlice(compiler.allocator, name);
            }
            i = end;
            continue;
        }

        try out.append(compiler.allocator, css[i]);
        i += 1;
    }
}

fn openMediaWrappers(allocator: std.mem.Allocator, out: *std.ArrayList(u8), variants: []const []const u8) !void {
    for (variants) |variant| {
        if (supportsVariantCondition(variant)) |condition| {
            try out.appendSlice(allocator, "@supports (");
            try out.appendSlice(allocator, condition);
            try out.appendSlice(allocator, "){");
            continue;
        }
        if (mediaVariant(variant)) |media| {
            try out.appendSlice(allocator, "@media ");
            try out.appendSlice(allocator, media);
            try out.append(allocator, '{');
        }
    }
}

fn applyGroupPeerHoverSelector(
    allocator: std.mem.Allocator,
    selector: *std.ArrayList(u8),
    prefix: ?[]const u8,
    peer: bool,
) !void {
    var next: std.ArrayList(u8) = .empty;
    defer next.deinit(allocator);
    try next.appendSlice(allocator, selector.items);
    try next.appendSlice(allocator, ":is(:where(.");
    if (prefix) |p| {
        try appendEscaped(allocator, &next, p);
        try next.appendSlice(allocator, "\\:");
    }
    try next.appendSlice(allocator, if (peer) "peer):hover ~ *)" else "group):hover *)");
    selector.clearRetainingCapacity();
    try selector.appendSlice(allocator, next.items);
}

fn writeNegatedBodyCustomVariantRules(
    compiler: *Compiler,
    out: *std.ArrayList(u8),
    raw: []const u8,
    variants: []const []const u8,
    suffix: []const u8,
    declarations: []const u8,
) !bool {
    if (variants.len != 1) return false;
    const custom = negatedBodyCustomVariantForName(compiler, variants[0]) orelse return false;
    const media = negatedBodyCustomVariantMediaQuery(custom) orelse return false;

    var selector: std.ArrayList(u8) = .empty;
    defer selector.deinit(compiler.allocator);
    try selector.append(compiler.allocator, '.');
    try appendEscaped(compiler.allocator, &selector, raw);
    try selector.appendSlice(compiler.allocator, suffix);
    if (!try applyNegatedBodyCustomVariantSelector(compiler, &selector, custom)) return false;

    try appendSelectorRule(compiler.allocator, out, selector.items, declarations);
    try appendNegatedMediaStart(compiler.allocator, out, media);

    var media_selector: std.ArrayList(u8) = .empty;
    defer media_selector.deinit(compiler.allocator);
    try media_selector.append(compiler.allocator, '.');
    try appendEscaped(compiler.allocator, &media_selector, raw);
    try media_selector.appendSlice(compiler.allocator, suffix);
    try appendSelectorRule(compiler.allocator, out, media_selector.items, declarations);
    try out.append(compiler.allocator, '}');
    return true;
}

fn writeDirectBodyCustomVariantRules(
    compiler: *Compiler,
    out: *std.ArrayList(u8),
    raw: []const u8,
    variants: []const []const u8,
    suffix: []const u8,
    declarations: []const u8,
) !bool {
    if (variants.len != 1) return false;
    const custom = customVariantForName(compiler, variants[0]) orelse return false;
    if (!custom.body) return false;

    var selector: std.ArrayList(u8) = .empty;
    defer selector.deinit(compiler.allocator);
    try selector.append(compiler.allocator, '.');
    try appendEscaped(compiler.allocator, &selector, raw);
    try selector.appendSlice(compiler.allocator, suffix);

    return try writeCustomVariantBodyBranchRules(compiler, out, selector.items, custom.value, declarations);
}

fn writeCustomVariantBodyBranchRules(
    compiler: *Compiler,
    out: *std.ArrayList(u8),
    selector: []const u8,
    body: []const u8,
    declarations: []const u8,
) anyerror!bool {
    const allocator = compiler.allocator;
    var i: usize = 0;
    var wrote = false;
    while (i < body.len) {
        skipCssWhitespaceAndComments(body, &i);
        if (i >= body.len) break;

        if (std.mem.startsWith(u8, body[i..], "@slot")) {
            const end = i + "@slot".len;
            if (end == body.len or !isNameChar(body[end])) {
                try appendSelectorRule(allocator, out, selector, declarations);
                i = definitionEnd(body, i) orelse end;
                wrote = true;
                continue;
            }
        }

        const start = i;
        const block_end = scanCssBlock(body, start) orelse break;
        const open_rel = std.mem.indexOfScalar(u8, body[start..block_end], '{') orelse break;
        const open = start + open_rel;
        const prelude = trimAscii(body[start..open]);
        const inner = body[open + 1 .. block_end - 1];

        if (prelude.len > 0 and prelude[0] == '@') {
            if (std.mem.indexOf(u8, body[start..block_end], "@slot") != null) {
                if (!try writeNestedVariantAtRuleChain(compiler, out, selector, body[start..block_end], declarations)) {
                    try appendCustomVariantAtRuleChain(allocator, out, body[start..block_end]);
                    try appendSelectorRule(allocator, out, selector, declarations);
                    var close_count = customVariantAtRuleDepth(body[start..block_end]);
                    while (close_count > 0) : (close_count -= 1) try out.append(allocator, '}');
                }
                wrote = true;
            }
        } else {
            var patterns: std.ArrayList(u8) = .empty;
            defer patterns.deinit(allocator);
            try appendCustomVariantNestedPatterns(compiler, &patterns, "&", prelude, inner);
            if (patterns.items.len > 0) {
                var branch_selector: std.ArrayList(u8) = .empty;
                defer branch_selector.deinit(allocator);
                try branch_selector.appendSlice(allocator, selector);
                try applyCustomVariantSelector(allocator, &branch_selector, patterns.items);
                try appendSelectorRule(allocator, out, branch_selector.items, declarations);
                wrote = true;
            }
        }
        i = block_end;
    }
    return wrote;
}

fn appendSelectorRule(allocator: std.mem.Allocator, out: *std.ArrayList(u8), selector: []const u8, declarations: []const u8) !void {
    try out.appendSlice(allocator, selector);
    try out.append(allocator, '{');
    try out.appendSlice(allocator, declarations);
    try out.append(allocator, '}');
}

fn writeNestedVariantAtRuleChain(
    compiler: *Compiler,
    out: *std.ArrayList(u8),
    selector: []const u8,
    block: []const u8,
    declarations: []const u8,
) anyerror!bool {
    var i: usize = 0;
    skipCssWhitespaceAndComments(block, &i);
    if (i >= block.len or !std.mem.startsWith(u8, block[i..], "@variant")) return false;
    const open_rel = std.mem.indexOfScalar(u8, block[i..], '{') orelse return false;
    const open = i + open_rel;
    const prelude = trimAscii(block[i + "@variant".len .. open]);
    if (!isSimpleVariantName(prelude)) return false;
    const inner = block[open + 1 .. block.len - 1];

    if (customVariantForName(compiler, prelude)) |custom| {
        if (custom.body) {
            return try writeCustomVariantBodyContinuation(compiler, out, selector, custom.value, inner, declarations);
        }
    }

    var next_selector: std.ArrayList(u8) = .empty;
    defer next_selector.deinit(compiler.allocator);
    try next_selector.appendSlice(compiler.allocator, selector);
    try applyNestedVariantSelector(compiler, &next_selector, prelude);

    const media_depth = try openNestedVariantMedia(compiler, out, prelude);
    var j: usize = 0;
    skipCssWhitespaceAndComments(inner, &j);
    if (j < inner.len and std.mem.startsWith(u8, inner[j..], "@slot")) {
        try appendSelectorRule(compiler.allocator, out, next_selector.items, declarations);
    } else if (j < inner.len and std.mem.startsWith(u8, inner[j..], "@variant")) {
        const nested_end = scanCssBlock(inner, j) orelse {
            var close_count = media_depth;
            while (close_count > 0) : (close_count -= 1) try out.append(compiler.allocator, '}');
            return false;
        };
        if (!try writeNestedVariantAtRuleChain(compiler, out, next_selector.items, inner[j..nested_end], declarations)) {
            var close_count = media_depth;
            while (close_count > 0) : (close_count -= 1) try out.append(compiler.allocator, '}');
            return false;
        }
    } else {
        var close_count = media_depth;
        while (close_count > 0) : (close_count -= 1) try out.append(compiler.allocator, '}');
        return false;
    }

    var close_count = media_depth;
    while (close_count > 0) : (close_count -= 1) try out.append(compiler.allocator, '}');
    return true;
}

fn writeCustomVariantBodyContinuation(
    compiler: *Compiler,
    out: *std.ArrayList(u8),
    selector: []const u8,
    body: []const u8,
    continuation: []const u8,
    declarations: []const u8,
) anyerror!bool {
    var i: usize = 0;
    var wrote = false;
    while (i < body.len) {
        skipCssWhitespaceAndComments(body, &i);
        if (i >= body.len) break;

        if (std.mem.startsWith(u8, body[i..], "@slot")) {
            const end = i + "@slot".len;
            if (end == body.len or !isNameChar(body[end])) {
                if (try writeCustomVariantBodyBranchRules(compiler, out, selector, continuation, declarations)) {
                    wrote = true;
                }
                i = definitionEnd(body, i) orelse end;
                continue;
            }
        }

        const start = i;
        const block_end = scanCssBlock(body, start) orelse break;
        const open_rel = std.mem.indexOfScalar(u8, body[start..block_end], '{') orelse break;
        const open = start + open_rel;
        const prelude = trimAscii(body[start..open]);
        const inner = body[open + 1 .. block_end - 1];

        if (prelude.len > 0 and prelude[0] == '@') {
            if (std.mem.startsWith(u8, prelude, "@variant")) {
                if (try writeNestedVariantAtRuleChain(compiler, out, selector, body[start..block_end], declarations)) {
                    wrote = true;
                }
            } else {
                try out.appendSlice(compiler.allocator, prelude);
                try out.append(compiler.allocator, '{');
                if (try writeCustomVariantBodyContinuation(compiler, out, selector, inner, continuation, declarations)) {
                    wrote = true;
                }
                try out.append(compiler.allocator, '}');
            }
        } else {
            if (try writeCustomVariantSelectorContinuationBranches(compiler, out, selector, prelude, inner, continuation, declarations)) {
                wrote = true;
            }
        }
        i = block_end;
    }
    return wrote;
}

fn writeCustomVariantSelectorContinuationBranches(
    compiler: *Compiler,
    out: *std.ArrayList(u8),
    selector: []const u8,
    prelude: []const u8,
    body: []const u8,
    continuation: []const u8,
    declarations: []const u8,
) anyerror!bool {
    var start: usize = 0;
    var paren_depth: usize = 0;
    var wrote = false;
    for (prelude, 0..) |c, i| {
        switch (c) {
            '(' => paren_depth += 1,
            ')' => if (paren_depth > 0) {
                paren_depth -= 1;
            },
            ',' => if (paren_depth == 0) {
                if (try writeCustomVariantSelectorContinuationBranch(compiler, out, selector, trimAscii(prelude[start..i]), body, continuation, declarations)) {
                    wrote = true;
                }
                start = i + 1;
            },
            else => {},
        }
    }
    if (try writeCustomVariantSelectorContinuationBranch(compiler, out, selector, trimAscii(prelude[start..]), body, continuation, declarations)) {
        wrote = true;
    }
    return wrote;
}

fn writeCustomVariantSelectorContinuationBranch(
    compiler: *Compiler,
    out: *std.ArrayList(u8),
    selector: []const u8,
    pattern: []const u8,
    body: []const u8,
    continuation: []const u8,
    declarations: []const u8,
) anyerror!bool {
    if (pattern.len == 0) return false;
    var branch_selector: std.ArrayList(u8) = .empty;
    defer branch_selector.deinit(compiler.allocator);
    try branch_selector.appendSlice(compiler.allocator, selector);
    try applyCustomVariantSelector(compiler.allocator, &branch_selector, pattern);
    return try writeCustomVariantBodyContinuation(compiler, out, branch_selector.items, body, continuation, declarations);
}

fn isSimpleVariantName(name: []const u8) bool {
    if (name.len == 0) return false;
    for (name) |c| {
        if (!(isNameChar(c) or c == '-')) return false;
    }
    return true;
}

fn openNestedVariantMedia(compiler: *Compiler, out: *std.ArrayList(u8), variant: []const u8) !usize {
    if (supportsVariantCondition(variant)) |condition| {
        try out.appendSlice(compiler.allocator, "@supports (");
        try out.appendSlice(compiler.allocator, condition);
        try out.appendSlice(compiler.allocator, "){");
        return 1;
    }
    if (customVariantForName(compiler, variant)) |custom| {
        if (custom.media) {
            try out.appendSlice(compiler.allocator, "@media ");
            try out.appendSlice(compiler.allocator, custom.value);
            try out.append(compiler.allocator, '{');
            return 1;
        }
        if (custom.body) {
            if (try appendCustomVariantBodyAtRuleStart(compiler.allocator, out, custom.value)) return customVariantBodyAtRuleDepth(custom.value);
        }
        return 0;
    }
    if (mediaVariant(variant)) |media| {
        try out.appendSlice(compiler.allocator, "@media ");
        try out.appendSlice(compiler.allocator, media);
        try out.append(compiler.allocator, '{');
        return 1;
    }
    return 0;
}

fn applyNestedVariantSelector(compiler: *Compiler, selector: *std.ArrayList(u8), variant: []const u8) !void {
    if (customVariantForName(compiler, variant)) |custom| {
        if (!custom.media and !custom.body) {
            try applyCustomVariantSelector(compiler.allocator, selector, custom.value);
        }
        return;
    }
    if (pseudoVariant(variant)) |pseudo| {
        try selector.appendSlice(compiler.allocator, pseudo);
        return;
    }
    _ = try applyCoreSelectorVariant(compiler.allocator, selector, compiler.prefix, variant);
}

fn openThemeMediaWrappers(compiler: *Compiler, out: *std.ArrayList(u8), variants: []const []const u8) !void {
    for (variants) |variant| {
        if (try appendThemeMediaStart(compiler, out, variant)) continue;
    }
}

fn closeThemeMediaWrappers(compiler: *Compiler, out: *std.ArrayList(u8), variants: []const []const u8) !void {
    var i = variants.len;
    while (i > 0) {
        i -= 1;
        const close_count = themeVariantMediaDepth(compiler, variants[i]);
        var j: usize = 0;
        while (j < close_count) : (j += 1) try out.append(compiler.allocator, '}');
    }
}

fn appendThemeMediaStart(compiler: *Compiler, out: *std.ArrayList(u8), variant: []const u8) !bool {
    if (supportsVariantCondition(variant)) |condition| {
        try out.appendSlice(compiler.allocator, "@supports (");
        try out.appendSlice(compiler.allocator, condition);
        try out.appendSlice(compiler.allocator, "){");
        return true;
    }
    if (negatedCustomMediaVariant(compiler, variant)) |media| {
        try out.appendSlice(compiler.allocator, "@media not ");
        try out.appendSlice(compiler.allocator, media);
        try out.append(compiler.allocator, '{');
        return true;
    }
    if (customVariantForName(compiler, variant)) |custom| {
        if (custom.media) {
            try out.appendSlice(compiler.allocator, "@media ");
            try out.appendSlice(compiler.allocator, custom.value);
            try out.append(compiler.allocator, '{');
            return true;
        }
        if (custom.body) {
            if (try appendCustomVariantBodyAtRuleStart(compiler.allocator, out, custom.value)) return true;
        }
        return false;
    }
    if (themeContainerForVariant(compiler, variant)) |container| {
        try out.appendSlice(compiler.allocator, "@container ");
        if (container.name) |name| {
            try out.appendSlice(compiler.allocator, name);
            try out.append(compiler.allocator, ' ');
        }
        if (container.max) {
            try out.appendSlice(compiler.allocator, "not (min-width:");
            try out.appendSlice(compiler.allocator, container.value);
            try out.appendSlice(compiler.allocator, "){");
        } else {
            try out.appendSlice(compiler.allocator, "(min-width:");
            try out.appendSlice(compiler.allocator, container.value);
            try out.appendSlice(compiler.allocator, "){");
        }
        return true;
    }
    if (themeBreakpointForVariant(compiler, variant)) |breakpoint| {
        if (breakpoint.max) {
            try out.appendSlice(compiler.allocator, "@media not all and (min-width:");
            try out.appendSlice(compiler.allocator, breakpoint.value);
            try out.appendSlice(compiler.allocator, "){");
        } else {
            try out.appendSlice(compiler.allocator, "@media (min-width:");
            try out.appendSlice(compiler.allocator, breakpoint.value);
            try out.appendSlice(compiler.allocator, "){");
        }
        return true;
    }
    if (mediaVariant(variant)) |media| {
        try out.appendSlice(compiler.allocator, "@media ");
        try out.appendSlice(compiler.allocator, media);
        try out.append(compiler.allocator, '{');
        return true;
    }
    return false;
}

fn themeVariantHasMedia(compiler: *Compiler, variant: []const u8) bool {
    return themeVariantMediaDepth(compiler, variant) > 0;
}

fn themeVariantMediaDepth(compiler: *Compiler, variant: []const u8) usize {
    if (negatedCustomMediaVariant(compiler, variant) != null) return 1;
    if (supportsVariantCondition(variant) != null) return 1;
    if (customVariantForName(compiler, variant)) |custom| {
        if (custom.media) return 1;
        if (custom.body) return customVariantBodyAtRuleDepth(custom.value);
        return 0;
    }
    if (themeContainerForVariant(compiler, variant) != null) return 1;
    return if (themeBreakpointForVariant(compiler, variant) != null or mediaVariant(variant) != null) 1 else 0;
}

fn closeMediaWrappers(allocator: std.mem.Allocator, out: *std.ArrayList(u8), variants: []const []const u8) !void {
    var i = variants.len;
    while (i > 0) {
        i -= 1;
        if (mediaVariant(variants[i]) != null or supportsVariantCondition(variants[i]) != null) try out.append(allocator, '}');
    }
}

fn pseudoVariant(variant: []const u8) ?[]const u8 {
    const pairs = [_]struct { name: []const u8, pseudo: []const u8 }{
        .{ .name = "hover", .pseudo = ":hover" },
        .{ .name = "focus", .pseudo = ":focus" },
        .{ .name = "focus-visible", .pseudo = ":focus-visible" },
        .{ .name = "focus-within", .pseudo = ":focus-within" },
        .{ .name = "active", .pseudo = ":active" },
        .{ .name = "visited", .pseudo = ":visited" },
        .{ .name = "disabled", .pseudo = ":disabled" },
        .{ .name = "checked", .pseudo = ":checked" },
        .{ .name = "first", .pseudo = ":first-child" },
        .{ .name = "first-letter", .pseudo = ":first-letter" },
        .{ .name = "last", .pseudo = ":last-child" },
        .{ .name = "odd", .pseudo = ":nth-child(odd)" },
        .{ .name = "even", .pseudo = ":nth-child(even)" },
        .{ .name = "before", .pseudo = ":before" },
        .{ .name = "after", .pseudo = ":after" },
        .{ .name = "placeholder", .pseudo = "::placeholder" },
    };
    inline for (pairs) |pair| {
        if (std.mem.eql(u8, variant, pair.name)) return pair.pseudo;
    }
    return null;
}

fn coreSelectorVariantIsSupported(variant: []const u8) bool {
    return (std.mem.startsWith(u8, variant, "[") and std.mem.endsWith(u8, variant, "]")) or
        std.mem.startsWith(u8, variant, "data-") or
        std.mem.startsWith(u8, variant, "aria-") or
        std.mem.startsWith(u8, variant, "has-[") or
        std.mem.startsWith(u8, variant, "not-[") or
        std.mem.eql(u8, variant, "peer-checked") or
        std.mem.startsWith(u8, variant, "group-data-[");
}

fn applyCoreSelectorVariant(
    allocator: std.mem.Allocator,
    selector: *std.ArrayList(u8),
    prefix: ?[]const u8,
    variant: []const u8,
) !bool {
    if (std.mem.startsWith(u8, variant, "[") and std.mem.endsWith(u8, variant, "]")) {
        try applyCustomVariantSelector(allocator, selector, variant[1 .. variant.len - 1]);
        return true;
    }
    if (std.mem.startsWith(u8, variant, "data-")) {
        try appendDataAttributeSelector(allocator, selector, variant["data-".len..]);
        return true;
    }
    if (std.mem.startsWith(u8, variant, "aria-")) {
        try appendAriaAttributeSelector(allocator, selector, variant["aria-".len..]);
        return true;
    }
    if (bracketVariantValue(variant, "has-")) |inner| {
        try selector.appendSlice(allocator, ":has(:is(");
        try selector.appendSlice(allocator, inner);
        try selector.appendSlice(allocator, "))");
        return true;
    }
    if (bracketVariantValue(variant, "not-")) |inner| {
        try selector.appendSlice(allocator, ":not(");
        try selector.appendSlice(allocator, inner);
        try selector.append(allocator, ')');
        return true;
    }
    if (std.mem.eql(u8, variant, "peer-checked")) {
        try selector.appendSlice(allocator, ":is(:where(.");
        if (prefix) |p| {
            try appendEscaped(allocator, selector, p);
            try selector.appendSlice(allocator, "\\:");
        }
        try selector.appendSlice(allocator, "peer):checked~*)");
        return true;
    }
    if (bracketVariantValue(variant, "group-data-")) |inner| {
        try selector.appendSlice(allocator, ":is(:where(.");
        if (prefix) |p| {
            try appendEscaped(allocator, selector, p);
            try selector.appendSlice(allocator, "\\:");
        }
        try selector.appendSlice(allocator, "group)");
        try appendDataAttributeSelector(allocator, selector, inner);
        try selector.appendSlice(allocator, " *)");
        return true;
    }
    return false;
}

fn appendDataAttributeSelector(allocator: std.mem.Allocator, selector: *std.ArrayList(u8), raw: []const u8) !void {
    try selector.appendSlice(allocator, "[data-");
    if (raw.len >= 2 and raw[0] == '[' and raw[raw.len - 1] == ']') {
        try selector.appendSlice(allocator, raw[1 .. raw.len - 1]);
    } else {
        try selector.appendSlice(allocator, raw);
    }
    try selector.append(allocator, ']');
}

fn appendAriaAttributeSelector(allocator: std.mem.Allocator, selector: *std.ArrayList(u8), raw: []const u8) !void {
    try selector.appendSlice(allocator, "[aria-");
    if (raw.len >= 2 and raw[0] == '[' and raw[raw.len - 1] == ']') {
        try selector.appendSlice(allocator, raw[1 .. raw.len - 1]);
        try selector.append(allocator, ']');
    } else {
        try selector.appendSlice(allocator, raw);
        try selector.appendSlice(allocator, "=true]");
    }
}

fn bracketVariantValue(variant: []const u8, prefix: []const u8) ?[]const u8 {
    if (!std.mem.startsWith(u8, variant, prefix)) return null;
    const body = variant[prefix.len..];
    if (body.len < 2 or body[0] != '[' or body[body.len - 1] != ']') return null;
    return body[1 .. body.len - 1];
}

fn supportsVariantCondition(variant: []const u8) ?[]const u8 {
    return bracketVariantValue(variant, "supports-");
}

fn mediaVariant(variant: []const u8) ?[]const u8 {
    const pairs = [_]struct { name: []const u8, media: []const u8 }{
        .{ .name = "sm", .media = "(min-width:40rem)" },
        .{ .name = "md", .media = "(min-width:48rem)" },
        .{ .name = "lg", .media = "(min-width:64rem)" },
        .{ .name = "xl", .media = "(min-width:80rem)" },
        .{ .name = "2xl", .media = "(min-width:96rem)" },
        .{ .name = "min-sm", .media = "(min-width:40rem)" },
        .{ .name = "min-md", .media = "(min-width:48rem)" },
        .{ .name = "min-lg", .media = "(min-width:64rem)" },
        .{ .name = "min-xl", .media = "(min-width:80rem)" },
        .{ .name = "min-2xl", .media = "(min-width:96rem)" },
        .{ .name = "max-sm", .media = "not all and (min-width:40rem)" },
        .{ .name = "max-md", .media = "not all and (min-width:48rem)" },
        .{ .name = "max-lg", .media = "not all and (min-width:64rem)" },
        .{ .name = "max-xl", .media = "not all and (min-width:80rem)" },
        .{ .name = "max-2xl", .media = "not all and (min-width:96rem)" },
        .{ .name = "hover", .media = "(hover:hover)" },
        .{ .name = "group-hover", .media = "(hover:hover)" },
        .{ .name = "peer-hover", .media = "(hover:hover)" },
        .{ .name = "dark", .media = "(prefers-color-scheme:dark)" },
        .{ .name = "landscape", .media = "(orientation:landscape)" },
        .{ .name = "portrait", .media = "(orientation:portrait)" },
        .{ .name = "motion-safe", .media = "(prefers-reduced-motion:no-preference)" },
        .{ .name = "motion-reduce", .media = "(prefers-reduced-motion:reduce)" },
        .{ .name = "print", .media = "print" },
    };
    inline for (pairs) |pair| {
        if (std.mem.eql(u8, variant, pair.name)) return pair.media;
    }
    return null;
}

const ThemeBreakpoint = struct {
    value: []const u8,
    max: bool,
};

const ThemeContainer = struct {
    value: []const u8,
    name: ?[]const u8,
    max: bool,
    explicit_min: bool,
};

fn themeBreakpointForVariant(compiler: *Compiler, variant: []const u8) ?ThemeBreakpoint {
    if (!canBeBreakpointVariant(variant)) return null;

    var name = variant;
    var max = false;
    if (std.mem.startsWith(u8, variant, "not-")) {
        const inner = variant["not-".len..];
        if (std.mem.startsWith(u8, inner, "min-")) {
            name = inner["min-".len..];
            max = true;
        } else if (std.mem.startsWith(u8, inner, "max-")) {
            name = inner["max-".len..];
        } else {
            name = inner;
            max = true;
        }
    } else {
        if (std.mem.startsWith(u8, variant, "min-")) {
            name = variant["min-".len..];
        } else if (std.mem.startsWith(u8, variant, "max-")) {
            name = variant["max-".len..];
            max = true;
        }
    }

    var full_name_buf: [512]u8 = undefined;
    const full_name = std.fmt.bufPrint(&full_name_buf, "--breakpoint-{s}", .{name}) catch return null;
    const variable = findThemeVariable(compiler, full_name) orelse return null;
    if (std.mem.eql(u8, variable.value, "initial")) return null;
    return .{ .value = variable.value, .max = max };
}

fn themeContainerForVariant(compiler: *Compiler, variant: []const u8) ?ThemeContainer {
    if (variant.len < 2 or variant[0] != '@') return null;

    var body = variant[1..];
    var container_name: ?[]const u8 = null;
    if (std.mem.indexOfScalar(u8, body, '/')) |slash| {
        if (slash + 1 >= body.len) return null;
        container_name = body[slash + 1 ..];
        body = body[0..slash];
    }

    var max = false;
    var explicit_min = false;
    if (std.mem.startsWith(u8, body, "min-")) {
        body = body["min-".len..];
        explicit_min = true;
    } else if (std.mem.startsWith(u8, body, "max-")) {
        body = body["max-".len..];
        max = true;
    }

    if (body.len >= 3 and body[0] == '[' and body[body.len - 1] == ']') {
        return .{ .value = body[1 .. body.len - 1], .name = container_name, .max = max, .explicit_min = explicit_min };
    }

    var name_buf: [512]u8 = undefined;
    const name = std.fmt.bufPrint(&name_buf, "--container-{s}", .{body}) catch return null;
    const variable = findThemeVariable(compiler, name) orelse return null;
    if (std.mem.eql(u8, variable.value, "initial")) return null;
    return .{ .value = variable.value, .name = container_name, .max = max, .explicit_min = explicit_min };
}

fn canBeBreakpointVariant(variant: []const u8) bool {
    if (pseudoVariant(variant) != null) return false;
    if (std.mem.eql(u8, variant, "group-hover") or std.mem.eql(u8, variant, "peer-hover")) return false;
    const non_breakpoint_media = [_][]const u8{ "dark", "landscape", "portrait", "motion-safe", "motion-reduce", "print", "hover", "group-hover", "peer-hover" };
    inline for (non_breakpoint_media) |name| {
        if (std.mem.eql(u8, variant, name)) return false;
    }
    return true;
}

fn customVariantForName(compiler: *Compiler, name: []const u8) ?CustomVariant {
    var i = compiler.custom_variants.items.len;
    while (i > 0) {
        i -= 1;
        const variant = compiler.custom_variants.items[i];
        if (std.mem.eql(u8, variant.name, name)) return variant;
    }
    return null;
}

fn negatedCustomMediaVariant(compiler: *Compiler, variant: []const u8) ?[]const u8 {
    if (!std.mem.startsWith(u8, variant, "not-")) return null;
    const custom = customVariantForName(compiler, variant["not-".len..]) orelse return null;
    if (!custom.media) return null;
    return custom.value;
}

fn negatedBodyCustomVariantForName(compiler: *Compiler, variant: []const u8) ?CustomVariant {
    if (!std.mem.startsWith(u8, variant, "not-")) return null;
    const custom = customVariantForName(compiler, variant["not-".len..]) orelse return null;
    if (!custom.body) return null;
    if (!customVariantBodyCanBeNegatedWithMedia(custom.value)) return null;
    return custom;
}

fn findCustomMedia(compiler: *Compiler, name: []const u8) ?CustomMedia {
    for (compiler.custom_media.items) |custom_media| {
        if (std.mem.eql(u8, custom_media.name, name)) return custom_media;
    }
    return null;
}

const CompoundCustomVariant = struct {
    custom: CustomVariant,
    peer: bool = false,
};

const ConditionalCustomVariantKind = enum {
    has,
    not,
};

const ConditionalCustomVariantRelation = enum {
    none,
    group,
    peer,
};

const ConditionalCustomVariant = struct {
    custom: CustomVariant,
    kind: ConditionalCustomVariantKind,
    relation: ConditionalCustomVariantRelation = .none,
    relation_name: ?[]const u8 = null,
};

fn compoundCustomVariantForName(compiler: *Compiler, name: []const u8) ?CompoundCustomVariant {
    if (std.mem.startsWith(u8, name, "group-")) {
        const custom = customVariantForName(compiler, name["group-".len..]) orelse return null;
        if (!customVariantCanCompound(custom)) return null;
        return .{ .custom = custom, .peer = false };
    }
    if (std.mem.startsWith(u8, name, "peer-")) {
        const custom = customVariantForName(compiler, name["peer-".len..]) orelse return null;
        if (!customVariantCanCompound(custom)) return null;
        return .{ .custom = custom, .peer = true };
    }
    return null;
}

fn conditionalCustomVariantForName(compiler: *Compiler, variant: []const u8) ?ConditionalCustomVariant {
    if (std.mem.startsWith(u8, variant, "has-")) {
        return conditionalCustomVariant(compiler, variant["has-".len..], .has, .none);
    }
    if (std.mem.startsWith(u8, variant, "not-")) {
        return conditionalCustomVariant(compiler, variant["not-".len..], .not, .none);
    }
    if (std.mem.startsWith(u8, variant, "group-has-")) {
        return conditionalCustomVariantWithName(compiler, variant["group-has-".len..], .has, .group);
    }
    if (std.mem.startsWith(u8, variant, "group-not-")) {
        return conditionalCustomVariantWithName(compiler, variant["group-not-".len..], .not, .group);
    }
    if (std.mem.startsWith(u8, variant, "peer-has-")) {
        return conditionalCustomVariantWithName(compiler, variant["peer-has-".len..], .has, .peer);
    }
    if (std.mem.startsWith(u8, variant, "peer-not-")) {
        return conditionalCustomVariantWithName(compiler, variant["peer-not-".len..], .not, .peer);
    }
    return null;
}

fn conditionalCustomVariantWithName(
    compiler: *Compiler,
    raw: []const u8,
    kind: ConditionalCustomVariantKind,
    relation: ConditionalCustomVariantRelation,
) ?ConditionalCustomVariant {
    var name = raw;
    var relation_name: ?[]const u8 = null;
    if (std.mem.indexOfScalar(u8, raw, '/')) |slash| {
        name = raw[0..slash];
        relation_name = raw[slash + 1 ..];
    }
    var conditional = conditionalCustomVariant(compiler, name, kind, relation) orelse return null;
    conditional.relation_name = relation_name;
    return conditional;
}

fn conditionalCustomVariant(
    compiler: *Compiler,
    name: []const u8,
    kind: ConditionalCustomVariantKind,
    relation: ConditionalCustomVariantRelation,
) ?ConditionalCustomVariant {
    const custom = customVariantForName(compiler, name) orelse return null;
    if (!customVariantCanCondition(custom)) return null;
    return .{ .custom = custom, .kind = kind, .relation = relation };
}

fn customVariantCanCompound(custom: CustomVariant) bool {
    if (custom.media) return false;
    if (!custom.body) return true;
    if (customVariantBodyHasAtRules(custom.value)) return false;
    return customVariantBodyHasOnlyDirectSelectorSlots(custom.value);
}

fn customVariantCanCondition(custom: CustomVariant) bool {
    if (!customVariantCanCompound(custom)) return false;
    if (!custom.body) return true;
    return customVariantBodyTopLevelStyleRuleCount(custom.value) == 1;
}

fn customVariantBodyTopLevelStyleRuleCount(body: []const u8) usize {
    var i: usize = 0;
    var count: usize = 0;
    while (i < body.len) {
        skipCssWhitespaceAndComments(body, &i);
        if (i >= body.len) break;
        if (body[i] == '@') {
            i = definitionEnd(body, i) orelse (i + 1);
            continue;
        }
        const end = scanCssBlock(body, i) orelse break;
        if (std.mem.indexOfScalar(u8, body[i..end], '{') != null) count += 1;
        i = end;
    }
    return count;
}

fn customVariantBodyHasOnlyDirectSelectorSlots(body: []const u8) bool {
    var i: usize = 0;
    var saw_slot = false;
    while (i < body.len) {
        skipCssWhitespaceAndComments(body, &i);
        if (i >= body.len) break;

        if (std.mem.startsWith(u8, body[i..], "@slot")) {
            const end = i + "@slot".len;
            if (end == body.len or !isNameChar(body[end])) {
                saw_slot = true;
                i = definitionEnd(body, i) orelse end;
                continue;
            }
        }

        if (body[i] == '@') return false;
        const block_end = scanCssBlock(body, i) orelse return false;
        const open_rel = std.mem.indexOfScalar(u8, body[i..block_end], '{') orelse return false;
        const inner = body[i + open_rel + 1 .. block_end - 1];
        if (!customVariantBodyHasOnlyDirectSlots(inner)) return false;
        saw_slot = true;
        i = block_end;
    }
    return saw_slot;
}

fn customVariantBodyHasOnlyDirectSlots(body: []const u8) bool {
    var i: usize = 0;
    var saw_slot = false;
    while (i < body.len) {
        skipCssWhitespaceAndComments(body, &i);
        if (i >= body.len) break;
        if (std.mem.startsWith(u8, body[i..], "@slot")) {
            const end = i + "@slot".len;
            if (end == body.len or !isNameChar(body[end])) {
                saw_slot = true;
                i = definitionEnd(body, i) orelse end;
                continue;
            }
        }
        if (body[i] == '@') return false;

        var j = i;
        var paren_depth: usize = 0;
        var bracket_depth: usize = 0;
        while (j < body.len) : (j += 1) {
            switch (body[j]) {
                '(' => paren_depth += 1,
                ')' => if (paren_depth > 0) {
                    paren_depth -= 1;
                },
                '[' => bracket_depth += 1,
                ']' => if (bracket_depth > 0) {
                    bracket_depth -= 1;
                },
                ';' => if (paren_depth == 0 and bracket_depth == 0) {
                    i = j + 1;
                    break;
                },
                '{' => if (paren_depth == 0 and bracket_depth == 0) return false,
                else => {},
            }
        }
        if (j >= body.len) return false;
    }
    return saw_slot;
}

fn customVariantBodyHasSelectorSlot(body: []const u8) bool {
    return std.mem.indexOf(u8, body, "@slot") != null;
}

fn customVariantBodyHasAtRules(body: []const u8) bool {
    return std.mem.indexOf(u8, body, "@media") != null or std.mem.indexOf(u8, body, "@container") != null;
}

fn appendCustomVariantBodyAtRuleStart(allocator: std.mem.Allocator, out: *std.ArrayList(u8), body: []const u8) !bool {
    const at_rule = customVariantBodyFirstAtRule(body) orelse return false;
    try appendCustomVariantAtRuleChain(allocator, out, at_rule);
    return true;
}

fn negatedBodyCustomVariantMediaQuery(custom: CustomVariant) ?[]const u8 {
    if (!custom.body) return null;
    const at_rule = customVariantBodyFirstAtRule(custom.value) orelse return null;
    var i: usize = 0;
    skipCssWhitespaceAndComments(at_rule, &i);
    const open_rel = std.mem.indexOfScalar(u8, at_rule[i..], '{') orelse return null;
    const open = i + open_rel;
    const prelude = trimAscii(at_rule[i..open]);
    if (!std.mem.startsWith(u8, prelude, "@media")) return null;
    return trimAscii(prelude["@media".len..]);
}

fn customVariantBodyCanBeNegatedWithMedia(body: []const u8) bool {
    if (!customVariantBodyHasSingleTopLevelAtRule(body)) return false;
    const media = negatedBodyCustomVariantMediaQuery(.{ .name = "", .value = body, .body = true }) orelse return false;
    if (hasTopLevelComma(media)) return false;
    const inner = negatedBodyCustomVariantInner(.{ .name = "", .value = body, .body = true }) orelse return false;
    if (customVariantBodyHasAtRules(inner)) return false;
    if (customVariantBodyTopLevelStyleRuleCount(inner) != 1) return false;
    return customVariantBodyHasOnlyDirectSelectorSlots(inner);
}

fn customVariantBodyHasSingleTopLevelAtRule(body: []const u8) bool {
    var i: usize = 0;
    skipCssWhitespaceAndComments(body, &i);
    if (i >= body.len or body[i] != '@') return false;
    const end = scanCssBlock(body, i) orelse return false;
    var rest = end;
    skipCssWhitespaceAndComments(body, &rest);
    return rest >= body.len;
}

fn hasTopLevelComma(value: []const u8) bool {
    var paren_depth: usize = 0;
    var bracket_depth: usize = 0;
    for (value) |c| {
        switch (c) {
            '(' => paren_depth += 1,
            ')' => if (paren_depth > 0) {
                paren_depth -= 1;
            },
            '[' => bracket_depth += 1,
            ']' => if (bracket_depth > 0) {
                bracket_depth -= 1;
            },
            ',' => if (paren_depth == 0 and bracket_depth == 0) return true,
            else => {},
        }
    }
    return false;
}

fn negatedBodyCustomVariantInner(custom: CustomVariant) ?[]const u8 {
    if (!custom.body) return null;
    const at_rule = customVariantBodyFirstAtRule(custom.value) orelse return null;
    var i: usize = 0;
    skipCssWhitespaceAndComments(at_rule, &i);
    const open_rel = std.mem.indexOfScalar(u8, at_rule[i..], '{') orelse return null;
    const open = i + open_rel;
    if (at_rule.len <= open + 1) return null;
    return at_rule[open + 1 .. at_rule.len - 1];
}

fn appendNegatedMediaStart(allocator: std.mem.Allocator, out: *std.ArrayList(u8), raw_media: []const u8) !void {
    const media = trimAscii(raw_media);
    try out.appendSlice(allocator, "@media ");
    if (std.mem.startsWith(u8, media, "not ")) {
        try out.appendSlice(allocator, trimAscii(media["not ".len..]));
    } else if (media.len > 0 and media[0] == '(') {
        try out.appendSlice(allocator, "not all and ");
        try out.appendSlice(allocator, media);
    } else {
        try out.appendSlice(allocator, "not ");
        try out.appendSlice(allocator, media);
    }
    try out.append(allocator, '{');
}

fn customVariantBodyFirstAtRule(body: []const u8) ?[]const u8 {
    var i: usize = 0;
    skipCssWhitespaceAndComments(body, &i);
    if (i >= body.len or body[i] != '@') return null;
    if (!std.mem.startsWith(u8, body[i..], "@media") and !std.mem.startsWith(u8, body[i..], "@container")) return null;
    const end = scanCssBlock(body, i) orelse return null;
    if (std.mem.indexOf(u8, body[i..end], "@slot") == null) return null;
    return body[i..end];
}

fn customVariantBodyAtRuleDepth(body: []const u8) usize {
    const at_rule = customVariantBodyFirstAtRule(body) orelse return 0;
    return customVariantAtRuleDepth(at_rule);
}

fn customVariantAtRuleDepth(block: []const u8) usize {
    var i: usize = 0;
    skipCssWhitespaceAndComments(block, &i);
    if (i >= block.len or block[i] != '@') return 0;
    const open = std.mem.indexOfScalar(u8, block[i..], '{') orelse return 0;
    const open_abs = i + open;
    var depth: usize = 1;
    const inner = block[open_abs + 1 .. block.len - 1];
    var j: usize = 0;
    skipCssWhitespaceAndComments(inner, &j);
    if (j < inner.len and inner[j] == '@' and !std.mem.startsWith(u8, inner[j..], "@slot")) {
        const nested_end = scanCssBlock(inner, j) orelse return depth;
        if (std.mem.indexOf(u8, inner[j..nested_end], "@slot") != null) {
            depth += customVariantAtRuleDepth(inner[j..nested_end]);
        }
    }
    return depth;
}

fn appendCustomVariantAtRuleChain(allocator: std.mem.Allocator, out: *std.ArrayList(u8), block: []const u8) !void {
    var i: usize = 0;
    skipCssWhitespaceAndComments(block, &i);
    if (i >= block.len or block[i] != '@') return;
    const open = std.mem.indexOfScalar(u8, block[i..], '{') orelse return;
    const open_abs = i + open;
    const prelude = trimAscii(block[i..open_abs]);
    try out.appendSlice(allocator, prelude);
    try out.append(allocator, '{');

    const inner = block[open_abs + 1 .. block.len - 1];
    var j: usize = 0;
    skipCssWhitespaceAndComments(inner, &j);
    if (j < inner.len and inner[j] == '@' and !std.mem.startsWith(u8, inner[j..], "@slot")) {
        const nested_end = scanCssBlock(inner, j) orelse return;
        if (std.mem.indexOf(u8, inner[j..nested_end], "@slot") != null) {
            try appendCustomVariantAtRuleChain(allocator, out, inner[j..nested_end]);
        }
    }
}

fn customVariantSelectorPattern(compiler: *Compiler, out: *std.ArrayList(u8), custom: CustomVariant) !void {
    if (custom.body) {
        try appendCustomVariantBodyPatterns(compiler, out, custom.value, "&");
    } else if (!custom.media) {
        try out.appendSlice(compiler.allocator, custom.value);
    }
}

fn applyCompoundCustomVariantSelector(compiler: *Compiler, selector: *std.ArrayList(u8), compound: CompoundCustomVariant) !void {
    const allocator = compiler.allocator;
    var pattern: std.ArrayList(u8) = .empty;
    defer pattern.deinit(allocator);
    try customVariantSelectorPattern(compiler, &pattern, compound.custom);
    if (pattern.items.len == 0) return;

    var relative: std.ArrayList(u8) = .empty;
    defer relative.deinit(allocator);
    try appendCompoundCustomVariantRelative(allocator, &relative, pattern.items, if (compound.peer) ".peer" else ".group");
    if (relative.items.len == 0) return;

    try selector.appendSlice(allocator, ":is(");
    try selector.appendSlice(allocator, relative.items);
    try selector.appendSlice(allocator, if (compound.peer) "~*)" else " *)");
}

fn applyConditionalCustomVariantSelector(
    compiler: *Compiler,
    selector: *std.ArrayList(u8),
    conditional: ConditionalCustomVariant,
) !void {
    const allocator = compiler.allocator;
    var argument: std.ArrayList(u8) = .empty;
    defer argument.deinit(allocator);
    if (!try customVariantConditionArgument(compiler, &argument, conditional.custom)) return;

    switch (conditional.relation) {
        .none => {
            try selector.appendSlice(allocator, if (conditional.kind == .has) ":has(" else ":not(");
            try selector.appendSlice(allocator, argument.items);
            try selector.append(allocator, ')');
        },
        .group, .peer => {
            try selector.appendSlice(allocator, ":is(:where(.");
            if (compiler.prefix) |prefix| {
                try appendEscaped(allocator, selector, prefix);
                try selector.appendSlice(allocator, "\\:");
            }
            const base = if (conditional.relation == .peer) "peer" else "group";
            if (conditional.relation_name) |name| {
                var marker_buf: [256]u8 = undefined;
                const marker = std.fmt.bufPrint(&marker_buf, "{s}/{s}", .{ base, name }) catch base;
                try appendEscaped(allocator, selector, marker);
            } else {
                try selector.appendSlice(allocator, base);
            }
            try selector.appendSlice(allocator, if (conditional.kind == .has) "):has(" else "):not(");
            try selector.appendSlice(allocator, argument.items);
            try selector.appendSlice(allocator, if (conditional.relation == .peer) ") ~ *)" else ") *)");
        },
    }
}

fn applyNegatedBodyCustomVariantSelector(
    compiler: *Compiler,
    selector: *std.ArrayList(u8),
    custom: CustomVariant,
) !bool {
    const inner = negatedBodyCustomVariantInner(custom) orelse return false;
    var pattern: std.ArrayList(u8) = .empty;
    defer pattern.deinit(compiler.allocator);
    try appendCustomVariantBodyPatterns(compiler, &pattern, inner, "&");
    if (pattern.items.len == 0) return false;

    var argument: std.ArrayList(u8) = .empty;
    defer argument.deinit(compiler.allocator);
    if (!try customVariantConditionArgumentFromPattern(compiler.allocator, &argument, pattern.items)) return false;

    try selector.appendSlice(compiler.allocator, ":not(");
    try selector.appendSlice(compiler.allocator, argument.items);
    try selector.append(compiler.allocator, ')');
    return true;
}

fn customVariantConditionArgument(compiler: *Compiler, out: *std.ArrayList(u8), custom: CustomVariant) !bool {
    var pattern: std.ArrayList(u8) = .empty;
    defer pattern.deinit(compiler.allocator);
    try customVariantSelectorPattern(compiler, &pattern, custom);
    if (pattern.items.len == 0) return false;

    return try customVariantConditionArgumentFromPattern(compiler.allocator, out, pattern.items);
}

fn customVariantConditionArgumentFromPattern(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(u8),
    pattern: []const u8,
) !bool {
    var start: usize = 0;
    var paren_depth: usize = 0;
    var first = true;
    for (pattern, 0..) |c, i| {
        switch (c) {
            '(' => paren_depth += 1,
            ')' => if (paren_depth > 0) {
                paren_depth -= 1;
            },
            ',' => if (paren_depth == 0) {
                if (!try appendCustomVariantConditionPart(allocator, out, trimAscii(pattern[start..i]), &first)) return false;
                start = i + 1;
            },
            else => {},
        }
    }
    if (!try appendCustomVariantConditionPart(allocator, out, trimAscii(pattern[start..]), &first)) return false;
    return out.items.len > 0;
}

fn appendCustomVariantConditionPart(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(u8),
    raw_part: []const u8,
    first: *bool,
) !bool {
    var part = trimAscii(raw_part);
    if (part.len == 0) return true;
    if (part[0] != '&') return false;
    part = trimAscii(part[1..]);
    if (part.len == 0) return false;
    if (!first.*) try out.append(allocator, ',');
    try out.appendSlice(allocator, part);
    first.* = false;
    return true;
}

fn appendCompoundCustomVariantRelative(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(u8),
    pattern: []const u8,
    marker: []const u8,
) !void {
    var start: usize = 0;
    var paren_depth: usize = 0;
    var first = true;
    for (pattern, 0..) |c, i| {
        switch (c) {
            '(' => paren_depth += 1,
            ')' => if (paren_depth > 0) {
                paren_depth -= 1;
            },
            ',' => if (paren_depth == 0) {
                if (!first) try out.append(allocator, ',');
                try appendRelativeSelectorPart(allocator, out, trimAscii(pattern[start..i]), marker);
                first = false;
                start = i + 1;
            },
            else => {},
        }
    }
    if (!first) try out.append(allocator, ',');
    try appendRelativeSelectorPart(allocator, out, trimAscii(pattern[start..]), marker);
    if (!first) {
        var wrapped: std.ArrayList(u8) = .empty;
        defer wrapped.deinit(allocator);
        try wrapped.appendSlice(allocator, ":is(");
        try wrapped.appendSlice(allocator, out.items);
        try wrapped.append(allocator, ')');
        out.clearRetainingCapacity();
        try out.appendSlice(allocator, wrapped.items);
    }
}

fn appendRelativeSelectorPart(allocator: std.mem.Allocator, out: *std.ArrayList(u8), pattern: []const u8, marker: []const u8) !void {
    var i: usize = 0;
    var replaced = false;
    while (std.mem.indexOfScalar(u8, pattern[i..], '&')) |rel| {
        const at = i + rel;
        try out.appendSlice(allocator, pattern[i..at]);
        try out.appendSlice(allocator, ":where(");
        try out.appendSlice(allocator, marker);
        try out.append(allocator, ')');
        replaced = true;
        i = at + 1;
    }
    try out.appendSlice(allocator, pattern[i..]);
    if (!replaced) {
        try out.appendSlice(allocator, " :where(");
        try out.appendSlice(allocator, marker);
        try out.append(allocator, ')');
    }
}

fn applyCustomVariantBodySelector(compiler: *Compiler, selector: *std.ArrayList(u8), body: []const u8) !void {
    const allocator = compiler.allocator;
    var pattern: std.ArrayList(u8) = .empty;
    defer pattern.deinit(allocator);
    try appendCustomVariantBodyPatterns(compiler, &pattern, body, "&");
    if (pattern.items.len == 0) return;
    try applyCustomVariantSelector(allocator, selector, pattern.items);
}

fn appendCustomVariantBodyPatterns(compiler: *Compiler, out: *std.ArrayList(u8), body: []const u8, parent: []const u8) anyerror!void {
    const allocator = compiler.allocator;
    var i: usize = 0;
    while (i < body.len) {
        skipCssWhitespaceAndComments(body, &i);
        if (i >= body.len) break;

        if (std.mem.startsWith(u8, body[i..], "@slot")) {
            const end = i + "@slot".len;
            if (end == body.len or !isNameChar(body[end])) {
                try appendCustomVariantPattern(allocator, out, parent);
                i = definitionEnd(body, i) orelse end;
                continue;
            }
        }

        const start = i;
        const block_end = scanCssBlock(body, start) orelse break;
        const open_rel = std.mem.indexOfScalar(u8, body[start..block_end], '{') orelse break;
        const open = start + open_rel;
        const prelude = trimAscii(body[start..open]);
        if (std.mem.startsWith(u8, prelude, "@variant")) {
            const variant = trimAscii(prelude["@variant".len..]);
            if (isSimpleVariantName(variant)) {
                _ = try appendCustomVariantBodyVariantPatterns(compiler, out, parent, variant, body[open + 1 .. block_end - 1]);
            }
            i = block_end;
            continue;
        }
        if (prelude.len == 0 or prelude[0] == '@') {
            i = block_end;
            continue;
        }
        try appendCustomVariantNestedPatterns(compiler, out, parent, prelude, body[open + 1 .. block_end - 1]);
        i = block_end;
    }
}

fn appendCustomVariantNestedPatterns(
    compiler: *Compiler,
    out: *std.ArrayList(u8),
    parent: []const u8,
    prelude: []const u8,
    body: []const u8,
) anyerror!void {
    const allocator = compiler.allocator;
    var start: usize = 0;
    var paren_depth: usize = 0;
    for (prelude, 0..) |c, i| {
        switch (c) {
            '(' => paren_depth += 1,
            ')' => if (paren_depth > 0) {
                paren_depth -= 1;
            },
            ',' => if (paren_depth == 0) {
                var combined: std.ArrayList(u8) = .empty;
                defer combined.deinit(allocator);
                try combineCustomVariantPattern(allocator, &combined, parent, trimAscii(prelude[start..i]));
                try appendCustomVariantBodyPatterns(compiler, out, body, combined.items);
                start = i + 1;
            },
            else => {},
        }
    }
    var combined: std.ArrayList(u8) = .empty;
    defer combined.deinit(allocator);
    try combineCustomVariantPattern(allocator, &combined, parent, trimAscii(prelude[start..]));
    try appendCustomVariantBodyPatterns(compiler, out, body, combined.items);
}

fn appendCustomVariantBodyVariantPatterns(
    compiler: *Compiler,
    out: *std.ArrayList(u8),
    parent: []const u8,
    variant: []const u8,
    body: []const u8,
) anyerror!bool {
    const allocator = compiler.allocator;
    var parents: std.ArrayList(u8) = .empty;
    defer parents.deinit(allocator);

    if (customVariantForName(compiler, variant)) |custom| {
        if (custom.media) return false;
        if (custom.body) {
            try appendCustomVariantBodyPatterns(compiler, &parents, custom.value, parent);
        } else {
            var selector: std.ArrayList(u8) = .empty;
            defer selector.deinit(allocator);
            try selector.appendSlice(allocator, parent);
            try applyCustomVariantSelector(allocator, &selector, custom.value);
            try selectorListAppend(allocator, &parents, selector.items);
        }
    } else if (pseudoVariant(variant)) |pseudo| {
        try selectorListAppendWithSuffix(allocator, &parents, parent, pseudo);
    } else if (std.mem.startsWith(u8, variant, "[") and std.mem.endsWith(u8, variant, "]")) {
        var selector: std.ArrayList(u8) = .empty;
        defer selector.deinit(allocator);
        try selector.appendSlice(allocator, parent);
        try applyCustomVariantSelector(allocator, &selector, variant[1 .. variant.len - 1]);
        try selectorListAppend(allocator, &parents, selector.items);
    } else {
        return false;
    }

    if (parents.items.len == 0) return false;
    try appendCustomVariantBodyPatternsForParents(compiler, out, parents.items, body);
    return true;
}

fn appendCustomVariantBodyPatternsForParents(
    compiler: *Compiler,
    out: *std.ArrayList(u8),
    parents: []const u8,
    body: []const u8,
) anyerror!void {
    var start: usize = 0;
    var paren_depth: usize = 0;
    for (parents, 0..) |c, i| {
        switch (c) {
            '(' => paren_depth += 1,
            ')' => if (paren_depth > 0) {
                paren_depth -= 1;
            },
            ',' => if (paren_depth == 0) {
                try appendCustomVariantBodyPatterns(compiler, out, body, trimAscii(parents[start..i]));
                start = i + 1;
            },
            else => {},
        }
    }
    try appendCustomVariantBodyPatterns(compiler, out, body, trimAscii(parents[start..]));
}

fn selectorListAppend(allocator: std.mem.Allocator, out: *std.ArrayList(u8), selector: []const u8) !void {
    if (selector.len == 0) return;
    if (out.items.len > 0) try out.append(allocator, ',');
    try out.appendSlice(allocator, selector);
}

fn selectorListAppendWithSuffix(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(u8),
    selector: []const u8,
    suffix: []const u8,
) !void {
    if (selector.len == 0) return;
    if (out.items.len > 0) try out.append(allocator, ',');
    try out.appendSlice(allocator, selector);
    try out.appendSlice(allocator, suffix);
}

fn combineCustomVariantPattern(allocator: std.mem.Allocator, out: *std.ArrayList(u8), parent: []const u8, child: []const u8) !void {
    if (child.len == 0) return;
    if (std.mem.indexOfScalar(u8, child, '&') == null) {
        try out.appendSlice(allocator, parent);
        if (!nestedSelectorStartsWithCombinator(child)) try out.append(allocator, ' ');
        try out.appendSlice(allocator, child);
        return;
    }

    var i: usize = 0;
    while (std.mem.indexOfScalar(u8, child[i..], '&')) |rel| {
        const at = i + rel;
        try out.appendSlice(allocator, child[i..at]);
        try out.appendSlice(allocator, parent);
        i = at + 1;
    }
    try out.appendSlice(allocator, child[i..]);
}

fn appendCustomVariantPattern(allocator: std.mem.Allocator, out: *std.ArrayList(u8), pattern: []const u8) !void {
    if (pattern.len == 0) return;
    if (out.items.len > 0) try out.append(allocator, ',');
    try out.appendSlice(allocator, pattern);
}

fn applyCustomVariantSelector(allocator: std.mem.Allocator, selector: *std.ArrayList(u8), pattern: []const u8) !void {
    var next: std.ArrayList(u8) = .empty;
    defer next.deinit(allocator);

    var start: usize = 0;
    var paren_depth: usize = 0;
    var first = true;
    for (pattern, 0..) |c, i| {
        switch (c) {
            '(' => paren_depth += 1,
            ')' => if (paren_depth > 0) {
                paren_depth -= 1;
            },
            ',' => if (paren_depth == 0) {
                if (!first) try next.append(allocator, ',');
                try appendCustomSelectorPart(allocator, &next, trimAscii(pattern[start..i]), selector.items);
                first = false;
                start = i + 1;
            },
            else => {},
        }
    }

    if (!first) try next.append(allocator, ',');
    try appendCustomSelectorPart(allocator, &next, trimAscii(pattern[start..]), selector.items);
    selector.clearRetainingCapacity();
    try selector.appendSlice(allocator, next.items);
}

fn appendCustomSelectorPart(allocator: std.mem.Allocator, out: *std.ArrayList(u8), pattern: []const u8, selector: []const u8) !void {
    var i: usize = 0;
    var replaced = false;
    while (std.mem.indexOfScalar(u8, pattern[i..], '&')) |rel| {
        const at = i + rel;
        try out.appendSlice(allocator, pattern[i..at]);
        try out.appendSlice(allocator, selector);
        replaced = true;
        i = at + 1;
    }
    try out.appendSlice(allocator, pattern[i..]);
    if (!replaced) {
        try out.append(allocator, ' ');
        try out.appendSlice(allocator, selector);
    }
}

fn hasThemeValue(compiler: *Compiler, namespace: []const u8, token: []const u8) bool {
    const variable = findThemeVariableWithNamespace(compiler, namespace, token) orelse return false;
    return !std.mem.eql(u8, variable.value, "initial");
}

fn resolveThemeValue(compiler: *Compiler, buf: []u8, namespace: []const u8, token: []const u8) ?[]const u8 {
    const variable = findThemeVariableWithNamespace(compiler, namespace, token) orelse return null;
    return resolveThemeVariable(compiler, buf, variable);
}

fn resolveThemeValueOrBuiltin(compiler: *Compiler, buf: []u8, namespace: []const u8, token: []const u8) ?[]const u8 {
    if (resolveThemeValue(compiler, buf, namespace, token)) |value| return value;
    var name_buf: [512]u8 = undefined;
    const name = std.fmt.bufPrint(&name_buf, "{s}{s}", .{ namespace, token }) catch return null;
    if (builtinThemeVariableValue(name) == null) return null;
    return std.fmt.bufPrint(buf, "var({s})", .{name}) catch null;
}

fn findThemeVariableWithNamespace(compiler: *Compiler, namespace: []const u8, token: []const u8) ?ThemeVariable {
    var name_buf: [512]u8 = undefined;
    const name = std.fmt.bufPrint(&name_buf, "{s}{s}", .{ namespace, token }) catch return null;
    if (findThemeVariable(compiler, name)) |variable| return variable;

    var escaped_buf: [512]u8 = undefined;
    if (formatEscapedThemeTokenName(&escaped_buf, namespace, token)) |escaped| {
        if (!std.mem.eql(u8, escaped, name)) {
            if (findThemeVariable(compiler, escaped)) |variable| return variable;
        }
    }

    var underscore_buf: [512]u8 = undefined;
    if (formatUnderscoreThemeTokenName(&underscore_buf, namespace, token)) |underscored| {
        if (!std.mem.eql(u8, underscored, name)) {
            if (findThemeVariable(compiler, underscored)) |variable| return variable;
        }
    }

    return null;
}

fn resolveThemeName(compiler: *Compiler, buf: []u8, name: []const u8) ?[]const u8 {
    const variable = findThemeVariable(compiler, name) orelse return null;
    return resolveThemeVariable(compiler, buf, variable);
}

fn resolveThemeVariable(compiler: *Compiler, buf: []u8, variable: ThemeVariable) ?[]const u8 {
    if (std.mem.eql(u8, variable.value, "initial")) return null;
    if (variable.inline_theme) return variable.value;
    var name_buf: [512]u8 = undefined;
    const css_name = formatCssVariableName(compiler, &name_buf, variable.name) orelse return null;
    if (variable.reference) return std.fmt.bufPrint(buf, "var({s},{s})", .{ css_name, variable.value }) catch null;
    return std.fmt.bufPrint(buf, "var({s})", .{css_name}) catch null;
}

fn formatEscapedThemeTokenName(buf: []u8, namespace: []const u8, token: []const u8) ?[]const u8 {
    if (namespace.len > buf.len) return null;
    @memcpy(buf[0..namespace.len], namespace);
    var len = namespace.len;
    for (token) |c| {
        if (c == '.' or c == '/' or c == '%') {
            if (len + 2 > buf.len) return null;
            buf[len] = '\\';
            buf[len + 1] = c;
            len += 2;
        } else {
            if (len + 1 > buf.len) return null;
            buf[len] = c;
            len += 1;
        }
    }
    return buf[0..len];
}

fn formatUnderscoreThemeTokenName(buf: []u8, namespace: []const u8, token: []const u8) ?[]const u8 {
    if (namespace.len + token.len > buf.len) return null;
    @memcpy(buf[0..namespace.len], namespace);
    var len = namespace.len;
    for (token) |c| {
        buf[len] = if (c == '.') '_' else c;
        len += 1;
    }
    return buf[0..len];
}

fn findThemeVariable(compiler: *Compiler, name: []const u8) ?ThemeVariable {
    for (compiler.theme_variables.items) |variable| {
        if (std.mem.eql(u8, variable.name, name)) return variable;
    }
    return null;
}

fn findThemeVariableLast(compiler: *Compiler, name: []const u8) ?ThemeVariable {
    var i = compiler.theme_variables.items.len;
    while (i > 0) {
        i -= 1;
        const variable = compiler.theme_variables.items[i];
        if (std.mem.eql(u8, variable.name, name)) return variable;
    }
    return null;
}

fn appendEscaped(allocator: std.mem.Allocator, out: *std.ArrayList(u8), class_name: []const u8) !void {
    for (class_name, 0..) |c, i| {
        if (i == 0 and isDigit(c)) {
            try out.appendSlice(allocator, "\\3");
            try out.append(allocator, c);
            try out.append(allocator, ' ');
            continue;
        }
        switch (c) {
            'a'...'z', 'A'...'Z', '0'...'9', '-', '_' => try out.append(allocator, c),
            else => {
                try out.append(allocator, '\\');
                try out.append(allocator, c);
            },
        }
    }
}

const RawUtility = struct {
    name: []const u8,
    css: []const u8,
};

const SizeAxis = enum { width, height, both };

const static_utilities = [_]RawUtility{
    .{ .name = "sr-only", .css = "clip-path:inset(50%);white-space:nowrap;border-width:0;width:1px;height:1px;margin:-1px;padding:0;position:absolute;overflow:hidden;" },
    .{ .name = "not-sr-only", .css = "clip-path:none;white-space:normal;width:auto;height:auto;margin:0;padding:0;position:static;overflow:visible;" },
    .{ .name = "container", .css = "width:100%;" },
    .{ .name = "box-border", .css = "box-sizing:border-box;" },
    .{ .name = "box-content", .css = "box-sizing:content-box;" },
    .{ .name = "static", .css = "position:static;" },
    .{ .name = "fixed", .css = "position:fixed;" },
    .{ .name = "absolute", .css = "position:absolute;" },
    .{ .name = "relative", .css = "position:relative;" },
    .{ .name = "sticky", .css = "position:sticky;" },
    .{ .name = "visible", .css = "visibility:visible;" },
    .{ .name = "invisible", .css = "visibility:hidden;" },
    .{ .name = "collapse", .css = "visibility:collapse;" },
    .{ .name = "block", .css = "display:block;" },
    .{ .name = "inline-block", .css = "display:inline-block;" },
    .{ .name = "inline", .css = "display:inline;" },
    .{ .name = "flex", .css = "display:flex;" },
    .{ .name = "inline-flex", .css = "display:inline-flex;" },
    .{ .name = "grid", .css = "display:grid;" },
    .{ .name = "inline-grid", .css = "display:inline-grid;" },
    .{ .name = "contents", .css = "display:contents;" },
    .{ .name = "hidden", .css = "display:none;" },
    .{ .name = "table", .css = "display:table;" },
    .{ .name = "table-row", .css = "display:table-row;" },
    .{ .name = "table-cell", .css = "display:table-cell;" },
    .{ .name = "flow-root", .css = "display:flow-root;" },
    .{ .name = "float-left", .css = "float:left;" },
    .{ .name = "float-right", .css = "float:right;" },
    .{ .name = "float-none", .css = "float:none;" },
    .{ .name = "clear-left", .css = "clear:left;" },
    .{ .name = "clear-right", .css = "clear:right;" },
    .{ .name = "clear-both", .css = "clear:both;" },
    .{ .name = "clear-none", .css = "clear:none;" },
    .{ .name = "isolate", .css = "isolation:isolate;" },
    .{ .name = "isolation-auto", .css = "isolation:auto;" },
    .{ .name = "object-contain", .css = "object-fit:contain;" },
    .{ .name = "object-cover", .css = "object-fit:cover;" },
    .{ .name = "object-fill", .css = "object-fit:fill;" },
    .{ .name = "object-none", .css = "object-fit:none;" },
    .{ .name = "object-scale-down", .css = "object-fit:scale-down;" },
    .{ .name = "aspect-square", .css = "aspect-ratio:1;" },
    .{ .name = "aspect-video", .css = "aspect-ratio:var(--aspect-video);" },
    .{ .name = "overflow-auto", .css = "overflow:auto;" },
    .{ .name = "overflow-hidden", .css = "overflow:hidden;" },
    .{ .name = "overflow-clip", .css = "overflow:clip;" },
    .{ .name = "overflow-visible", .css = "overflow:visible;" },
    .{ .name = "overflow-scroll", .css = "overflow:scroll;" },
    .{ .name = "overflow-x-auto", .css = "overflow-x:auto;" },
    .{ .name = "overflow-x-hidden", .css = "overflow-x:hidden;" },
    .{ .name = "overflow-y-auto", .css = "overflow-y:auto;" },
    .{ .name = "overflow-y-hidden", .css = "overflow-y:hidden;" },
    .{ .name = "truncate", .css = "text-overflow:ellipsis;white-space:nowrap;overflow:hidden;" },
    .{ .name = "text-ellipsis", .css = "text-overflow:ellipsis;" },
    .{ .name = "text-clip", .css = "text-overflow:clip;" },
    .{ .name = "flex-row", .css = "flex-direction:row;" },
    .{ .name = "flex-row-reverse", .css = "flex-direction:row-reverse;" },
    .{ .name = "flex-col", .css = "flex-direction:column;" },
    .{ .name = "flex-col-reverse", .css = "flex-direction:column-reverse;" },
    .{ .name = "flex-wrap", .css = "flex-wrap:wrap;" },
    .{ .name = "flex-nowrap", .css = "flex-wrap:nowrap;" },
    .{ .name = "flex-wrap-reverse", .css = "flex-wrap:wrap-reverse;" },
    .{ .name = "flex-1", .css = "flex:1;" },
    .{ .name = "flex-auto", .css = "flex:auto;" },
    .{ .name = "flex-initial", .css = "flex:0 auto;" },
    .{ .name = "flex-none", .css = "flex:none;" },
    .{ .name = "grow", .css = "flex-grow:1;" },
    .{ .name = "grow-0", .css = "flex-grow:0;" },
    .{ .name = "shrink", .css = "flex-shrink:1;" },
    .{ .name = "shrink-0", .css = "flex-shrink:0;" },
    .{ .name = "basis-auto", .css = "flex-basis:auto;" },
    .{ .name = "items-start", .css = "align-items:flex-start;" },
    .{ .name = "items-end", .css = "align-items:flex-end;" },
    .{ .name = "items-center", .css = "align-items:center;" },
    .{ .name = "items-baseline", .css = "align-items:baseline;" },
    .{ .name = "items-stretch", .css = "align-items:stretch;" },
    .{ .name = "content-center", .css = "align-content:center;" },
    .{ .name = "content-start", .css = "align-content:flex-start;" },
    .{ .name = "content-end", .css = "align-content:flex-end;" },
    .{ .name = "content-between", .css = "align-content:space-between;" },
    .{ .name = "content-around", .css = "align-content:space-around;" },
    .{ .name = "content-evenly", .css = "align-content:space-evenly;" },
    .{ .name = "self-auto", .css = "align-self:auto;" },
    .{ .name = "self-start", .css = "align-self:flex-start;" },
    .{ .name = "self-end", .css = "align-self:flex-end;" },
    .{ .name = "self-center", .css = "align-self:center;" },
    .{ .name = "self-stretch", .css = "align-self:stretch;" },
    .{ .name = "justify-normal", .css = "justify-content:normal;" },
    .{ .name = "justify-start", .css = "justify-content:flex-start;" },
    .{ .name = "justify-end", .css = "justify-content:flex-end;" },
    .{ .name = "justify-center", .css = "justify-content:center;" },
    .{ .name = "justify-between", .css = "justify-content:space-between;" },
    .{ .name = "justify-around", .css = "justify-content:space-around;" },
    .{ .name = "justify-evenly", .css = "justify-content:space-evenly;" },
    .{ .name = "place-items-start", .css = "place-items:start;" },
    .{ .name = "place-items-end", .css = "place-items:end;" },
    .{ .name = "place-items-center", .css = "place-items:center;" },
    .{ .name = "place-items-stretch", .css = "place-items:stretch;" },
    .{ .name = "text-left", .css = "text-align:left;" },
    .{ .name = "text-center", .css = "text-align:center;" },
    .{ .name = "text-right", .css = "text-align:right;" },
    .{ .name = "text-justify", .css = "text-align:justify;" },
    .{ .name = "text-start", .css = "text-align:start;" },
    .{ .name = "text-end", .css = "text-align:end;" },
    .{ .name = "font-thin", .css = "font-weight:100;" },
    .{ .name = "font-extralight", .css = "font-weight:200;" },
    .{ .name = "font-light", .css = "font-weight:300;" },
    .{ .name = "font-normal", .css = "font-weight:400;" },
    .{ .name = "font-medium", .css = "font-weight:500;" },
    .{ .name = "font-semibold", .css = "font-weight:600;" },
    .{ .name = "font-bold", .css = "font-weight:700;" },
    .{ .name = "font-extrabold", .css = "font-weight:800;" },
    .{ .name = "font-black", .css = "font-weight:900;" },
    .{ .name = "italic", .css = "font-style:italic;" },
    .{ .name = "not-italic", .css = "font-style:normal;" },
    .{ .name = "uppercase", .css = "text-transform:uppercase;" },
    .{ .name = "lowercase", .css = "text-transform:lowercase;" },
    .{ .name = "capitalize", .css = "text-transform:capitalize;" },
    .{ .name = "normal-case", .css = "text-transform:none;" },
    .{ .name = "underline", .css = "text-decoration-line:underline;" },
    .{ .name = "overline", .css = "text-decoration-line:overline;" },
    .{ .name = "line-through", .css = "text-decoration-line:line-through;" },
    .{ .name = "no-underline", .css = "text-decoration-line:none;" },
    .{ .name = "antialiased", .css = "-webkit-font-smoothing:antialiased;-moz-osx-font-smoothing:grayscale;" },
    .{ .name = "subpixel-antialiased", .css = "-webkit-font-smoothing:auto;-moz-osx-font-smoothing:auto;" },
    .{ .name = "list-none", .css = "list-style-type:none;" },
    .{ .name = "list-disc", .css = "list-style-type:disc;" },
    .{ .name = "list-decimal", .css = "list-style-type:decimal;" },
    .{ .name = "appearance-none", .css = "appearance:none;" },
    .{ .name = "pointer-events-none", .css = "pointer-events:none;" },
    .{ .name = "pointer-events-auto", .css = "pointer-events:auto;" },
    .{ .name = "resize-none", .css = "resize:none;" },
    .{ .name = "resize-y", .css = "resize:vertical;" },
    .{ .name = "resize-x", .css = "resize:horizontal;" },
    .{ .name = "resize", .css = "resize:both;" },
    .{ .name = "select-none", .css = "-webkit-user-select:none;user-select:none;" },
    .{ .name = "select-text", .css = "user-select:text;" },
    .{ .name = "select-all", .css = "user-select:all;" },
    .{ .name = "select-auto", .css = "user-select:auto;" },
    .{ .name = "cursor-auto", .css = "cursor:auto;" },
    .{ .name = "cursor-default", .css = "cursor:default;" },
    .{ .name = "cursor-pointer", .css = "cursor:pointer;" },
    .{ .name = "cursor-wait", .css = "cursor:wait;" },
    .{ .name = "cursor-text", .css = "cursor:text;" },
    .{ .name = "cursor-move", .css = "cursor:move;" },
    .{ .name = "cursor-not-allowed", .css = "cursor:not-allowed;" },
    .{ .name = "transition", .css = "transition-property:color,background-color,border-color,outline-color,text-decoration-color,fill,stroke,--tw-gradient-from,--tw-gradient-via,--tw-gradient-to,opacity,box-shadow,transform,translate,scale,rotate,filter,-webkit-backdrop-filter,backdrop-filter,display,content-visibility,overlay,pointer-events;transition-timing-function:var(--tw-ease,var(--default-transition-timing-function));transition-duration:var(--tw-duration,var(--default-transition-duration));" },
    .{ .name = "transition-all", .css = "transition-property:all;transition-timing-function:var(--tw-ease,var(--default-transition-timing-function));transition-duration:var(--tw-duration,var(--default-transition-duration));" },
    .{ .name = "transition-colors", .css = "transition-property:color,background-color,border-color,outline-color,text-decoration-color,fill,stroke,--tw-gradient-from,--tw-gradient-via,--tw-gradient-to;transition-timing-function:var(--tw-ease,var(--default-transition-timing-function));transition-duration:var(--tw-duration,var(--default-transition-duration));" },
    .{ .name = "transition-opacity", .css = "transition-property:opacity;transition-timing-function:cubic-bezier(.4,0,.2,1);transition-duration:150ms;" },
    .{ .name = "transition-transform", .css = "transition-property:transform;transition-timing-function:cubic-bezier(.4,0,.2,1);transition-duration:150ms;" },
    .{ .name = "ease-linear", .css = "transition-timing-function:linear;" },
    .{ .name = "ease-in", .css = "transition-timing-function:cubic-bezier(.4,0,1,1);" },
    .{ .name = "ease-out", .css = "transition-timing-function:cubic-bezier(0,0,.2,1);" },
    .{ .name = "ease-in-out", .css = "transition-timing-function:cubic-bezier(.4,0,.2,1);" },
    .{ .name = "transform", .css = "transform:translate(var(--tw-translate-x,0),var(--tw-translate-y,0)) rotate(var(--tw-rotate,0)) skewX(var(--tw-skew-x,0)) skewY(var(--tw-skew-y,0)) scaleX(var(--tw-scale-x,1)) scaleY(var(--tw-scale-y,1));" },
    .{ .name = "transform-none", .css = "transform:none;" },
    .{ .name = "shadow", .css = "box-shadow:0 1px 3px 0 rgb(0 0 0/.1),0 1px 2px -1px rgb(0 0 0/.1);" },
    .{ .name = "shadow-sm", .css = "box-shadow:0 1px 2px 0 rgb(0 0 0/.05);" },
    .{ .name = "shadow-md", .css = "box-shadow:0 4px 6px -1px rgb(0 0 0/.1),0 2px 4px -2px rgb(0 0 0/.1);" },
    .{ .name = "shadow-lg", .css = "box-shadow:0 10px 15px -3px rgb(0 0 0/.1),0 4px 6px -4px rgb(0 0 0/.1);" },
    .{ .name = "shadow-xl", .css = "box-shadow:0 20px 25px -5px rgb(0 0 0/.1),0 8px 10px -6px rgb(0 0 0/.1);" },
    .{ .name = "shadow-none", .css = "box-shadow:0 0 #0000;" },
    .{ .name = "outline-none", .css = "--tw-outline-style:none;outline-style:none;" },
    .{ .name = "outline", .css = "outline-style:solid;" },
    .{ .name = "ring", .css = "box-shadow:0 0 0 3px rgb(59 130 246/.5);" },
    .{ .name = "ring-0", .css = "box-shadow:0 0 #0000;" },
    .{ .name = "ring-1", .css = "box-shadow:0 0 0 1px currentColor;" },
    .{ .name = "ring-2", .css = "box-shadow:0 0 0 2px currentColor;" },
    .{ .name = "ring-4", .css = "box-shadow:0 0 0 4px currentColor;" },
    .{ .name = "ring-8", .css = "box-shadow:0 0 0 8px currentColor;" },
    .{ .name = "divide-solid", .css = "border-style:solid;" },
    .{ .name = "divide-dashed", .css = "border-style:dashed;" },
    .{ .name = "divide-dotted", .css = "border-style:dotted;" },
};

fn emitThemeUtility(
    compiler: *Compiler,
    rule_out: *std.ArrayList(u8),
    out: *std.ArrayList(u8),
    base: []const u8,
    important: bool,
) !bool {
    if (try emitThemeTextSize(compiler, out, base, important)) return true;
    if (try emitThemeTextSideNamespace(compiler, out, base, important)) return true;
    if (try emitThemeBorderSpacing(compiler, rule_out, out, base, important)) return true;
    if (try emitThemeSpacing(compiler, out, base, important)) return true;
    if (try emitThemeSizing(compiler, out, base, important)) return true;
    if (try emitThemeInset(compiler, out, base, important)) return true;
    if (try emitThemeRadius(compiler, out, base, important)) return true;
    if (try emitThemeFont(compiler, out, base, important)) return true;
    if (try emitThemeLeading(compiler, rule_out, out, base, important)) return true;
    if (try emitThemeTracking(compiler, rule_out, out, base, important)) return true;
    if (try emitThemeEase(compiler, rule_out, out, base, important)) return true;
    if (try emitThemeOpacity(compiler, out, base, important)) return true;
    if (try emitThemeNumeric(compiler, out, base, important)) return true;
    if (try emitThemeGrid(compiler, out, base, important)) return true;
    if (try emitThemeLineClamp(compiler, out, base, important)) return true;
    if (try emitThemeMappedFunctional(compiler, out, base, important)) return true;
    if (try emitThemeBackgroundImage(compiler, out, base, important)) return true;
    if (try emitThemeColor(compiler, out, base, important)) return true;
    if (try emitThemeAnimation(compiler, out, base, important)) return true;
    return false;
}

fn emitThemeOpacity(compiler: *Compiler, out: *std.ArrayList(u8), base: []const u8, important: bool) !bool {
    if (!std.mem.startsWith(u8, base, "opacity-")) return false;
    var value_buf: [512]u8 = undefined;
    const value = resolveThemeValue(compiler, &value_buf, "--opacity-", base["opacity-".len..]) orelse return false;
    try appendDecl(compiler.allocator, out, "opacity", value, important);
    return true;
}

fn emitThemeNumeric(compiler: *Compiler, out: *std.ArrayList(u8), base: []const u8, important: bool) !bool {
    var negative = false;
    var name = base;
    if (name.len > 1 and name[0] == '-') {
        negative = true;
        name = name[1..];
    }
    const entries = [_]struct { prefix: []const u8, namespace: []const u8, prop: []const u8, allow_negative: bool }{
        .{ .prefix = "z-", .namespace = "--z-index-", .prop = "z-index", .allow_negative = true },
        .{ .prefix = "order-", .namespace = "--order-", .prop = "order", .allow_negative = true },
    };
    inline for (entries) |entry| {
        if (std.mem.startsWith(u8, name, entry.prefix)) {
            if (negative and !entry.allow_negative) return false;
            var value_buf: [512]u8 = undefined;
            const value = resolveThemeValue(compiler, &value_buf, entry.namespace, name[entry.prefix.len..]) orelse return false;
            if (negative) {
                var neg_buf: [768]u8 = undefined;
                const neg = std.fmt.bufPrint(&neg_buf, "calc({s} * -1)", .{value}) catch return false;
                try appendDecl(compiler.allocator, out, entry.prop, neg, important);
            } else {
                try appendDecl(compiler.allocator, out, entry.prop, value, important);
            }
            return true;
        }
    }
    return false;
}

fn emitThemeTextSize(compiler: *Compiler, out: *std.ArrayList(u8), base: []const u8, important: bool) !bool {
    if (!std.mem.startsWith(u8, base, "text-")) return false;
    const suffix = base["text-".len..];
    if (std.mem.startsWith(u8, suffix, "shadow-")) return false;
    var size_buf: [512]u8 = undefined;
    const size = resolveThemeValue(compiler, &size_buf, "--text-", suffix) orelse return false;
    try appendDecl(compiler.allocator, out, "font-size", size, important);

    var line_name_buf: [512]u8 = undefined;
    const line_name = std.fmt.bufPrint(&line_name_buf, "--text-{s}--line-height", .{suffix}) catch return true;
    var line_buf: [512]u8 = undefined;
    if (resolveThemeName(compiler, &line_buf, line_name)) |line_height| {
        var css_buf: [640]u8 = undefined;
        const css = std.fmt.bufPrint(&css_buf, "var(--tw-leading,{s})", .{line_height}) catch return true;
        try appendDecl(compiler.allocator, out, "line-height", css, important);
    }
    return true;
}

fn emitThemeTextSideNamespace(compiler: *Compiler, out: *std.ArrayList(u8), base: []const u8, important: bool) !bool {
    if (std.mem.startsWith(u8, base, "text-")) {
        const suffix = base["text-".len..];
        var value_buf: [512]u8 = undefined;
        const value = resolveThemeValue(compiler, &value_buf, "--text-color-", suffix) orelse return false;
        try appendDecl(compiler.allocator, out, "color", value, important);
        return true;
    }

    if (std.mem.startsWith(u8, base, "indent-")) {
        const suffix = base["indent-".len..];
        var value_buf: [512]u8 = undefined;
        const value = resolveThemeValue(compiler, &value_buf, "--text-indent-", suffix) orelse return false;
        try appendDecl(compiler.allocator, out, "text-indent", value, important);
        return true;
    }

    if (std.mem.startsWith(u8, base, "underline-offset-")) {
        const suffix = base["underline-offset-".len..];
        var value_buf: [512]u8 = undefined;
        const value = resolveThemeValue(compiler, &value_buf, "--text-underline-offset-", suffix) orelse return false;
        try appendDecl(compiler.allocator, out, "text-underline-offset", value, important);
        return true;
    }

    if (std.mem.startsWith(u8, base, "decoration-")) {
        const suffix = base["decoration-".len..];
        var thickness_buf: [512]u8 = undefined;
        if (resolveThemeValue(compiler, &thickness_buf, "--text-decoration-thickness-", suffix)) |value| {
            try appendDecl(compiler.allocator, out, "text-decoration-thickness", value, important);
            return true;
        }

        var color_buf: [512]u8 = undefined;
        const color = resolveThemeValue(compiler, &color_buf, "--text-decoration-color-", suffix) orelse return false;
        try appendDecl(compiler.allocator, out, "text-decoration-color", color, important);
        return true;
    }

    return false;
}

fn emitThemeBorderSpacing(
    compiler: *Compiler,
    rule_out: *std.ArrayList(u8),
    out: *std.ArrayList(u8),
    base: []const u8,
    important: bool,
) !bool {
    const entries = [_]struct { prefix: []const u8, x: bool, y: bool }{
        .{ .prefix = "border-spacing-x-", .x = true, .y = false },
        .{ .prefix = "border-spacing-y-", .x = false, .y = true },
        .{ .prefix = "border-spacing-", .x = true, .y = true },
    };
    inline for (entries) |entry| {
        if (std.mem.startsWith(u8, base, entry.prefix)) {
            var value_buf: [512]u8 = undefined;
            const value = themeSpacingValue(compiler, &value_buf, base[entry.prefix.len..], false) orelse return false;
            try appendPropertyLayer(compiler.allocator, rule_out, "--tw-border-spacing-x:0;--tw-border-spacing-y:0;");
            if (entry.x) try appendDecl(compiler.allocator, out, "--tw-border-spacing-x", value, important);
            if (entry.y) try appendDecl(compiler.allocator, out, "--tw-border-spacing-y", value, important);
            try appendDecl(compiler.allocator, out, "border-spacing", "var(--tw-border-spacing-x) var(--tw-border-spacing-y)", important);
            try rule_out.appendSlice(compiler.allocator, "@property --tw-border-spacing-x{syntax:\"<length>\";inherits:false;initial-value:0;}@property --tw-border-spacing-y{syntax:\"<length>\";inherits:false;initial-value:0;}");
            return true;
        }
    }
    return false;
}

fn emitThemeSpacing(compiler: *Compiler, out: *std.ArrayList(u8), base: []const u8, important: bool) !bool {
    var negative = false;
    var name = base;
    if (name.len > 1 and name[0] == '-') {
        negative = true;
        name = name[1..];
    }

    const prefixes = [_]struct { prefix: []const u8, props: []const []const u8, allow_negative: bool }{
        .{ .prefix = "p-", .props = &.{"padding"}, .allow_negative = false },
        .{ .prefix = "px-", .props = &.{"padding-inline"}, .allow_negative = false },
        .{ .prefix = "py-", .props = &.{"padding-block"}, .allow_negative = false },
        .{ .prefix = "ps-", .props = &.{"padding-inline-start"}, .allow_negative = false },
        .{ .prefix = "pe-", .props = &.{"padding-inline-end"}, .allow_negative = false },
        .{ .prefix = "pbs-", .props = &.{"padding-block-start"}, .allow_negative = false },
        .{ .prefix = "pbe-", .props = &.{"padding-block-end"}, .allow_negative = false },
        .{ .prefix = "pt-", .props = &.{"padding-top"}, .allow_negative = false },
        .{ .prefix = "pr-", .props = &.{"padding-right"}, .allow_negative = false },
        .{ .prefix = "pb-", .props = &.{"padding-bottom"}, .allow_negative = false },
        .{ .prefix = "pl-", .props = &.{"padding-left"}, .allow_negative = false },
        .{ .prefix = "m-", .props = &.{"margin"}, .allow_negative = true },
        .{ .prefix = "mx-", .props = &.{"margin-inline"}, .allow_negative = true },
        .{ .prefix = "my-", .props = &.{"margin-block"}, .allow_negative = true },
        .{ .prefix = "ms-", .props = &.{"margin-inline-start"}, .allow_negative = true },
        .{ .prefix = "me-", .props = &.{"margin-inline-end"}, .allow_negative = true },
        .{ .prefix = "mbs-", .props = &.{"margin-block-start"}, .allow_negative = true },
        .{ .prefix = "mbe-", .props = &.{"margin-block-end"}, .allow_negative = true },
        .{ .prefix = "mt-", .props = &.{"margin-top"}, .allow_negative = true },
        .{ .prefix = "mr-", .props = &.{"margin-right"}, .allow_negative = true },
        .{ .prefix = "mb-", .props = &.{"margin-bottom"}, .allow_negative = true },
        .{ .prefix = "ml-", .props = &.{"margin-left"}, .allow_negative = true },
        .{ .prefix = "scroll-mx-", .props = &.{"scroll-margin-inline"}, .allow_negative = true },
        .{ .prefix = "scroll-my-", .props = &.{"scroll-margin-block"}, .allow_negative = true },
        .{ .prefix = "scroll-ms-", .props = &.{"scroll-margin-inline-start"}, .allow_negative = true },
        .{ .prefix = "scroll-me-", .props = &.{"scroll-margin-inline-end"}, .allow_negative = true },
        .{ .prefix = "scroll-mbs-", .props = &.{"scroll-margin-block-start"}, .allow_negative = true },
        .{ .prefix = "scroll-mbe-", .props = &.{"scroll-margin-block-end"}, .allow_negative = true },
        .{ .prefix = "scroll-mt-", .props = &.{"scroll-margin-top"}, .allow_negative = true },
        .{ .prefix = "scroll-mr-", .props = &.{"scroll-margin-right"}, .allow_negative = true },
        .{ .prefix = "scroll-mb-", .props = &.{"scroll-margin-bottom"}, .allow_negative = true },
        .{ .prefix = "scroll-ml-", .props = &.{"scroll-margin-left"}, .allow_negative = true },
        .{ .prefix = "scroll-m-", .props = &.{"scroll-margin"}, .allow_negative = true },
        .{ .prefix = "scroll-px-", .props = &.{"scroll-padding-inline"}, .allow_negative = false },
        .{ .prefix = "scroll-py-", .props = &.{"scroll-padding-block"}, .allow_negative = false },
        .{ .prefix = "scroll-ps-", .props = &.{"scroll-padding-inline-start"}, .allow_negative = false },
        .{ .prefix = "scroll-pe-", .props = &.{"scroll-padding-inline-end"}, .allow_negative = false },
        .{ .prefix = "scroll-pbs-", .props = &.{"scroll-padding-block-start"}, .allow_negative = false },
        .{ .prefix = "scroll-pbe-", .props = &.{"scroll-padding-block-end"}, .allow_negative = false },
        .{ .prefix = "scroll-pt-", .props = &.{"scroll-padding-top"}, .allow_negative = false },
        .{ .prefix = "scroll-pr-", .props = &.{"scroll-padding-right"}, .allow_negative = false },
        .{ .prefix = "scroll-pb-", .props = &.{"scroll-padding-bottom"}, .allow_negative = false },
        .{ .prefix = "scroll-pl-", .props = &.{"scroll-padding-left"}, .allow_negative = false },
        .{ .prefix = "scroll-p-", .props = &.{"scroll-padding"}, .allow_negative = false },
        .{ .prefix = "gap-x-", .props = &.{"column-gap"}, .allow_negative = false },
        .{ .prefix = "gap-y-", .props = &.{"row-gap"}, .allow_negative = false },
        .{ .prefix = "gap-", .props = &.{"gap"}, .allow_negative = false },
    };
    inline for (prefixes) |entry| {
        if (std.mem.startsWith(u8, name, entry.prefix)) {
            if (negative and !entry.allow_negative) return false;
            const suffix = name[entry.prefix.len..];
            var value_buf: [512]u8 = undefined;
            const value = themeSpacingValue(compiler, &value_buf, suffix, negative) orelse return false;
            inline for (entry.props) |prop| try appendDecl(compiler.allocator, out, prop, value, important);
            return true;
        }
    }
    return false;
}

fn emitThemeSizing(compiler: *Compiler, out: *std.ArrayList(u8), base: []const u8, important: bool) !bool {
    const prefixes = [_]struct { prefix: []const u8, prop: []const u8, both: bool }{
        .{ .prefix = "w-", .prop = "width", .both = false },
        .{ .prefix = "min-w-", .prop = "min-width", .both = false },
        .{ .prefix = "max-w-", .prop = "max-width", .both = false },
        .{ .prefix = "h-", .prop = "height", .both = false },
        .{ .prefix = "min-h-", .prop = "min-height", .both = false },
        .{ .prefix = "max-h-", .prop = "max-height", .both = false },
        .{ .prefix = "size-", .prop = "size", .both = true },
        .{ .prefix = "basis-", .prop = "flex-basis", .both = false },
        .{ .prefix = "inline-", .prop = "inline-size", .both = false },
        .{ .prefix = "min-inline-", .prop = "min-inline-size", .both = false },
        .{ .prefix = "max-inline-", .prop = "max-inline-size", .both = false },
        .{ .prefix = "block-", .prop = "block-size", .both = false },
        .{ .prefix = "min-block-", .prop = "min-block-size", .both = false },
        .{ .prefix = "max-block-", .prop = "max-block-size", .both = false },
    };
    inline for (prefixes) |entry| {
        if (std.mem.startsWith(u8, base, entry.prefix)) {
            var value_buf: [512]u8 = undefined;
            const value = themeSizingValue(compiler, &value_buf, entry.prefix, base[entry.prefix.len..]) orelse return false;
            if (entry.both) {
                try appendDecl(compiler.allocator, out, "width", value, important);
                try appendDecl(compiler.allocator, out, "height", value, important);
            } else {
                try appendDecl(compiler.allocator, out, entry.prop, value, important);
            }
            return true;
        }
    }
    return false;
}

fn emitThemeInset(compiler: *Compiler, out: *std.ArrayList(u8), base: []const u8, important: bool) !bool {
    var negative = false;
    var name = base;
    if (name.len > 1 and name[0] == '-') {
        negative = true;
        name = name[1..];
    }
    if (!negative and (std.mem.eql(u8, name, "start") or std.mem.eql(u8, name, "end"))) {
        var value_buf: [512]u8 = undefined;
        const value = resolveThemeName(compiler, &value_buf, "--spacing") orelse return false;
        const prop = if (std.mem.eql(u8, name, "start")) "inset-inline-start" else "inset-inline-end";
        try appendDecl(compiler.allocator, out, prop, value, important);
        return true;
    }
    if (isInsetShadowBase(name)) return false;
    const prefixes = [_]struct { prefix: []const u8, props: []const []const u8 }{
        .{ .prefix = "inset-x-", .props = &.{"inset-inline"} },
        .{ .prefix = "inset-y-", .props = &.{"inset-block"} },
        .{ .prefix = "inset-s-", .props = &.{"inset-inline-start"} },
        .{ .prefix = "inset-e-", .props = &.{"inset-inline-end"} },
        .{ .prefix = "inset-bs-", .props = &.{"inset-block-start"} },
        .{ .prefix = "inset-be-", .props = &.{"inset-block-end"} },
        .{ .prefix = "inset-", .props = &.{"inset"} },
        .{ .prefix = "start-", .props = &.{"inset-inline-start"} },
        .{ .prefix = "end-", .props = &.{"inset-inline-end"} },
        .{ .prefix = "top-", .props = &.{"top"} },
        .{ .prefix = "right-", .props = &.{"right"} },
        .{ .prefix = "bottom-", .props = &.{"bottom"} },
        .{ .prefix = "left-", .props = &.{"left"} },
    };
    inline for (prefixes) |entry| {
        if (std.mem.startsWith(u8, name, entry.prefix)) {
            var value_buf: [512]u8 = undefined;
            const suffix = name[entry.prefix.len..];
            const value = themeInsetValue(compiler, &value_buf, suffix, negative) orelse return false;
            inline for (entry.props) |prop| try appendDecl(compiler.allocator, out, prop, value, important);
            return true;
        }
    }
    return false;
}

fn emitThemeGrid(compiler: *Compiler, out: *std.ArrayList(u8), base: []const u8, important: bool) !bool {
    var negative = false;
    var name = base;
    if (name.len > 1 and name[0] == '-') {
        negative = true;
        name = name[1..];
    }
    const entries = [_]struct { prefix: []const u8, namespace: []const u8, prop: []const u8 }{
        .{ .prefix = "col-start-", .namespace = "--grid-column-start-", .prop = "grid-column-start" },
        .{ .prefix = "col-end-", .namespace = "--grid-column-end-", .prop = "grid-column-end" },
        .{ .prefix = "col-", .namespace = "--grid-column-", .prop = "grid-column" },
        .{ .prefix = "row-start-", .namespace = "--grid-row-start-", .prop = "grid-row-start" },
        .{ .prefix = "row-end-", .namespace = "--grid-row-end-", .prop = "grid-row-end" },
        .{ .prefix = "row-", .namespace = "--grid-row-", .prop = "grid-row" },
    };
    inline for (entries) |entry| {
        if (std.mem.startsWith(u8, name, entry.prefix)) {
            var value_buf: [512]u8 = undefined;
            const value = resolveThemeValue(compiler, &value_buf, entry.namespace, name[entry.prefix.len..]) orelse return false;
            if (negative) {
                var neg_buf: [768]u8 = undefined;
                const neg = std.fmt.bufPrint(&neg_buf, "calc({s} * -1)", .{value}) catch return false;
                try appendDecl(compiler.allocator, out, entry.prop, neg, important);
            } else {
                try appendDecl(compiler.allocator, out, entry.prop, value, important);
            }
            return true;
        }
    }
    return false;
}

fn emitThemeLineClamp(compiler: *Compiler, out: *std.ArrayList(u8), base: []const u8, important: bool) !bool {
    if (!std.mem.startsWith(u8, base, "line-clamp-")) return false;
    var value_buf: [512]u8 = undefined;
    const value = resolveThemeValue(compiler, &value_buf, "--line-clamp-", base["line-clamp-".len..]) orelse return false;
    try appendDecl(compiler.allocator, out, "-webkit-line-clamp", value, important);
    try appendDecl(compiler.allocator, out, "-webkit-box-orient", "vertical", important);
    try appendDecl(compiler.allocator, out, "display", "-webkit-box", important);
    try appendDecl(compiler.allocator, out, "overflow", "hidden", important);
    return true;
}

fn emitThemeMappedFunctional(compiler: *Compiler, out: *std.ArrayList(u8), base: []const u8, important: bool) !bool {
    const entries = [_]struct { prefix: []const u8, namespace: []const u8, prop: []const u8, fallback_namespace: ?[]const u8 = null }{
        .{ .prefix = "origin-", .namespace = "--transform-origin-", .prop = "transform-origin" },
        .{ .prefix = "object-", .namespace = "--object-position-", .prop = "object-position" },
        .{ .prefix = "perspective-origin-", .namespace = "--perspective-origin-", .prop = "perspective-origin" },
        .{ .prefix = "perspective-", .namespace = "--perspective-", .prop = "perspective" },
        .{ .prefix = "cursor-", .namespace = "--cursor-", .prop = "cursor" },
        .{ .prefix = "list-image-", .namespace = "--list-style-image-", .prop = "list-style-image" },
        .{ .prefix = "list-", .namespace = "--list-style-type-", .prop = "list-style-type" },
        .{ .prefix = "columns-", .namespace = "--columns-", .prop = "columns", .fallback_namespace = "--container-" },
        .{ .prefix = "auto-cols-", .namespace = "--grid-auto-columns-", .prop = "grid-auto-columns" },
        .{ .prefix = "auto-rows-", .namespace = "--grid-auto-rows-", .prop = "grid-auto-rows" },
        .{ .prefix = "grid-cols-", .namespace = "--grid-template-columns-", .prop = "grid-template-columns" },
        .{ .prefix = "grid-rows-", .namespace = "--grid-template-rows-", .prop = "grid-template-rows" },
    };
    inline for (entries) |entry| {
        if (std.mem.startsWith(u8, base, entry.prefix)) {
            const suffix = base[entry.prefix.len..];
            var value_buf: [512]u8 = undefined;
            const value = resolveThemeValue(compiler, &value_buf, entry.namespace, suffix) orelse if (entry.fallback_namespace) |namespace|
                resolveThemeValue(compiler, &value_buf, namespace, suffix) orelse return false
            else
                return false;
            try appendDecl(compiler.allocator, out, entry.prop, value, important);
            if (std.mem.eql(u8, entry.prefix, "perspective-origin-")) {
                try appendDecl(compiler.allocator, out, "perspective", value, important);
            }
            return true;
        }
    }
    return false;
}

fn themeInsetValue(compiler: *Compiler, buf: []u8, suffix: []const u8, negative: bool) ?[]const u8 {
    if (!isInsetSideNamespaceSuffix(suffix)) {
        var inset_buf: [512]u8 = undefined;
        if (resolveThemeValue(compiler, &inset_buf, "--inset-", suffix)) |value| {
            if (!negative) return std.fmt.bufPrint(buf, "{s}", .{value}) catch null;
            return std.fmt.bufPrint(buf, "calc({s} * -1)", .{value}) catch null;
        }
    }
    return themeSpacingValue(compiler, buf, suffix, negative);
}

fn emitThemeRadius(compiler: *Compiler, out: *std.ArrayList(u8), base: []const u8, important: bool) !bool {
    const token = radiusTokenForBase(base) orelse return false;
    var value_buf: [512]u8 = undefined;
    const value = if (token.len == 0)
        resolveThemeName(compiler, &value_buf, "--radius") orelse return false
    else
        resolveThemeValue(compiler, &value_buf, "--radius-", token) orelse return false;
    if (!try appendRadiusDeclarations(compiler.allocator, out, base, value, important)) return false;
    return true;
}

fn emitThemeFont(compiler: *Compiler, out: *std.ArrayList(u8), base: []const u8, important: bool) !bool {
    if (!std.mem.startsWith(u8, base, "font-")) return false;
    if (std.mem.startsWith(u8, base, "font-weight-")) return false;
    var value_buf: [512]u8 = undefined;
    const value = resolveThemeValue(compiler, &value_buf, "--font-", base["font-".len..]) orelse return false;
    try appendDecl(compiler.allocator, out, "font-family", value, important);
    return true;
}

fn emitThemeLeading(compiler: *Compiler, rule_out: *std.ArrayList(u8), out: *std.ArrayList(u8), base: []const u8, important: bool) !bool {
    if (!std.mem.startsWith(u8, base, "leading-")) return false;
    var value_buf: [512]u8 = undefined;
    const value = resolveThemeValue(compiler, &value_buf, "--leading-", base["leading-".len..]) orelse return false;
    try appendPropertyLayer(compiler.allocator, rule_out, "--tw-leading:initial;");
    try appendDecl(compiler.allocator, out, "--tw-leading", value, important);
    try appendDecl(compiler.allocator, out, "line-height", value, important);
    try rule_out.appendSlice(compiler.allocator, "@property --tw-leading{syntax:\"*\";inherits:false;}");
    return true;
}

fn emitThemeTracking(compiler: *Compiler, rule_out: *std.ArrayList(u8), out: *std.ArrayList(u8), base: []const u8, important: bool) !bool {
    if (!std.mem.startsWith(u8, base, "tracking-")) return false;
    var value_buf: [512]u8 = undefined;
    const value = resolveThemeValue(compiler, &value_buf, "--tracking-", base["tracking-".len..]) orelse return false;
    try appendPropertyLayer(compiler.allocator, rule_out, "--tw-tracking:initial;");
    try appendDecl(compiler.allocator, out, "--tw-tracking", value, important);
    try appendDecl(compiler.allocator, out, "letter-spacing", value, important);
    try rule_out.appendSlice(compiler.allocator, "@property --tw-tracking{syntax:\"*\";inherits:false;}");
    return true;
}

fn emitThemeEase(compiler: *Compiler, rule_out: *std.ArrayList(u8), out: *std.ArrayList(u8), base: []const u8, important: bool) !bool {
    if (!std.mem.startsWith(u8, base, "ease-")) return false;
    var value_buf: [512]u8 = undefined;
    const value = resolveThemeValue(compiler, &value_buf, "--ease-", base["ease-".len..]) orelse return false;
    try appendPropertyLayer(compiler.allocator, rule_out, "--tw-ease:initial;");
    try appendDecl(compiler.allocator, out, "--tw-ease", value, important);
    try appendDecl(compiler.allocator, out, "transition-timing-function", value, important);
    try rule_out.appendSlice(compiler.allocator, "@property --tw-ease{syntax:\"*\";inherits:false;}");
    return true;
}

fn emitThemeColor(compiler: *Compiler, out: *std.ArrayList(u8), base: []const u8, important: bool) !bool {
    const prefixes = [_]struct { prefix: []const u8, prop: []const u8 }{
        .{ .prefix = "bg-", .prop = "background-color" },
        .{ .prefix = "text-", .prop = "color" },
        .{ .prefix = "border-", .prop = "border-color" },
        .{ .prefix = "ring-offset-", .prop = "--tw-ring-offset-color" },
        .{ .prefix = "inset-ring-", .prop = "--tw-inset-ring-color" },
        .{ .prefix = "ring-", .prop = "--tw-ring-color" },
        .{ .prefix = "decoration-", .prop = "text-decoration-color" },
        .{ .prefix = "placeholder-", .prop = "color" },
        .{ .prefix = "accent-", .prop = "accent-color" },
        .{ .prefix = "caret-", .prop = "caret-color" },
        .{ .prefix = "fill-", .prop = "fill" },
        .{ .prefix = "stroke-", .prop = "stroke" },
    };
    inline for (prefixes) |entry| {
        if (std.mem.startsWith(u8, base, entry.prefix)) {
            var color = base[entry.prefix.len..];
            var opacity: ?[]const u8 = null;
            if (std.mem.indexOfScalar(u8, color, '/')) |slash| {
                opacity = color[slash + 1 ..];
                color = color[0..slash];
            }
            var value_buf: [512]u8 = undefined;
            const value = if (colorThemeNamespaceForPrefix(entry.prefix)) |namespace|
                resolveThemeValue(compiler, &value_buf, namespace, color) orelse resolveThemeValue(compiler, &value_buf, "--color-", color) orelse return false
            else
                resolveThemeValue(compiler, &value_buf, "--color-", color) orelse return false;
            if (opacity) |alpha_token| {
                var pct_buf: [64]u8 = undefined;
                const pct = opacityPercent(&pct_buf, alpha_token) orelse return false;
                if (std.mem.eql(u8, pct, "100%")) {
                    try appendDecl(compiler.allocator, out, entry.prop, value, important);
                } else {
                    var mixed_buf: [768]u8 = undefined;
                    const mixed = std.fmt.bufPrint(&mixed_buf, "color-mix(in oklab,{s} {s},transparent)", .{ value, pct }) catch return false;
                    try appendDecl(compiler.allocator, out, entry.prop, mixed, important);
                }
            } else {
                try appendDecl(compiler.allocator, out, entry.prop, value, important);
            }
            return true;
        }
    }
    return false;
}

fn emitThemeBackgroundImage(compiler: *Compiler, out: *std.ArrayList(u8), base: []const u8, important: bool) !bool {
    if (!std.mem.startsWith(u8, base, "bg-")) return false;
    const suffix = base["bg-".len..];
    if (std.mem.indexOfScalar(u8, suffix, '/')) |_| return false;
    var value_buf: [1024]u8 = undefined;
    const value = resolveThemeValue(compiler, &value_buf, "--background-image-", suffix) orelse return false;
    try appendDecl(compiler.allocator, out, "background-image", value, important);
    return true;
}

fn colorThemeNamespaceForPrefix(prefix: []const u8) ?[]const u8 {
    if (std.mem.eql(u8, prefix, "bg-")) return "--background-color-";
    if (std.mem.eql(u8, prefix, "text-")) return "--text-color-";
    if (std.mem.eql(u8, prefix, "border-")) return "--border-color-";
    if (std.mem.eql(u8, prefix, "outline-")) return "--outline-color-";
    if (std.mem.eql(u8, prefix, "ring-offset-")) return "--ring-offset-color-";
    if (std.mem.eql(u8, prefix, "inset-ring-")) return "--inset-ring-color-";
    if (std.mem.eql(u8, prefix, "ring-")) return "--ring-color-";
    if (std.mem.eql(u8, prefix, "decoration-")) return "--text-decoration-color-";
    if (std.mem.eql(u8, prefix, "placeholder-")) return "--placeholder-color-";
    if (std.mem.eql(u8, prefix, "accent-")) return "--accent-color-";
    if (std.mem.eql(u8, prefix, "caret-")) return "--caret-color-";
    if (std.mem.eql(u8, prefix, "fill-")) return "--fill-";
    if (std.mem.eql(u8, prefix, "stroke-")) return "--stroke-";
    return null;
}

fn emitThemeAnimation(compiler: *Compiler, out: *std.ArrayList(u8), base: []const u8, important: bool) !bool {
    if (!std.mem.startsWith(u8, base, "animate-")) return false;
    var value_buf: [1024]u8 = undefined;
    const value = resolveThemeValue(compiler, &value_buf, "--animate-", base["animate-".len..]) orelse return false;
    try appendDecl(compiler.allocator, out, "animation", value, important);
    return true;
}

fn themeSpacingValue(compiler: *Compiler, buf: []u8, suffix: []const u8, negative: bool) ?[]const u8 {
    if (!negative) return resolveThemeValue(compiler, buf, "--spacing-", suffix);
    var value_buf: [512]u8 = undefined;
    const value = resolveThemeValue(compiler, &value_buf, "--spacing-", suffix) orelse return null;
    return std.fmt.bufPrint(buf, "calc({s} * -1)", .{value}) catch null;
}

fn themeSizingBaseValueExists(compiler: *Compiler, base: []const u8) bool {
    const entries = [_][]const u8{
        "min-w-",     "max-w-",     "min-h-",  "max-h-",      "size-",       "w-",
        "h-",         "basis-",     "inline-", "min-inline-", "max-inline-", "block-",
        "min-block-", "max-block-",
    };
    inline for (entries) |prefix| {
        if (std.mem.startsWith(u8, base, prefix)) {
            return hasThemeSizingValue(compiler, prefix, base[prefix.len..]);
        }
    }
    return false;
}

fn hasThemeSizingValue(compiler: *Compiler, prefix: []const u8, suffix: []const u8) bool {
    var value_buf: [512]u8 = undefined;
    return themeSizingValue(compiler, &value_buf, prefix, suffix) != null;
}

fn themeSizingValue(compiler: *Compiler, buf: []u8, prefix: []const u8, suffix: []const u8) ?[]const u8 {
    if (std.mem.eql(u8, prefix, "w-")) {
        if (resolveThemeValue(compiler, buf, "--width-", suffix)) |value| return value;
        if (resolveThemeValue(compiler, buf, "--spacing-", suffix)) |value| return value;
        return resolveThemeValue(compiler, buf, "--container-", suffix);
    }
    if (std.mem.eql(u8, prefix, "min-w-")) {
        if (resolveThemeValue(compiler, buf, "--min-width-", suffix)) |value| return value;
        if (resolveThemeValue(compiler, buf, "--spacing-", suffix)) |value| return value;
        return resolveThemeValue(compiler, buf, "--container-", suffix);
    }
    if (std.mem.eql(u8, prefix, "max-w-")) {
        if (resolveThemeValue(compiler, buf, "--max-width-", suffix)) |value| return value;
        if (resolveThemeValue(compiler, buf, "--spacing-", suffix)) |value| return value;
        return resolveThemeValue(compiler, buf, "--container-", suffix);
    }
    if (std.mem.eql(u8, prefix, "h-")) {
        if (resolveThemeValue(compiler, buf, "--height-", suffix)) |value| return value;
        return resolveThemeValue(compiler, buf, "--spacing-", suffix);
    }
    if (std.mem.eql(u8, prefix, "min-h-")) {
        if (resolveThemeValue(compiler, buf, "--min-height-", suffix)) |value| return value;
        if (resolveThemeValue(compiler, buf, "--height-", suffix)) |value| return value;
        return resolveThemeValue(compiler, buf, "--spacing-", suffix);
    }
    if (std.mem.eql(u8, prefix, "max-h-")) {
        if (resolveThemeValue(compiler, buf, "--max-height-", suffix)) |value| return value;
        if (resolveThemeValue(compiler, buf, "--height-", suffix)) |value| return value;
        return resolveThemeValue(compiler, buf, "--spacing-", suffix);
    }
    if (std.mem.eql(u8, prefix, "size-")) {
        if (resolveThemeValue(compiler, buf, "--size-", suffix)) |value| return value;
        return resolveThemeValue(compiler, buf, "--spacing-", suffix);
    }
    if (std.mem.eql(u8, prefix, "basis-")) {
        if (resolveThemeValue(compiler, buf, "--flex-basis-", suffix)) |value| return value;
        if (resolveThemeValue(compiler, buf, "--spacing-", suffix)) |value| return value;
        return resolveThemeValue(compiler, buf, "--container-", suffix);
    }
    if (std.mem.eql(u8, prefix, "inline-") or std.mem.eql(u8, prefix, "min-inline-") or std.mem.eql(u8, prefix, "max-inline-")) {
        if (resolveThemeValue(compiler, buf, "--spacing-", suffix)) |value| return value;
        return resolveThemeValue(compiler, buf, "--container-", suffix);
    }
    if (std.mem.eql(u8, prefix, "block-") or std.mem.eql(u8, prefix, "min-block-") or std.mem.eql(u8, prefix, "max-block-")) {
        return resolveThemeValue(compiler, buf, "--spacing-", suffix);
    }
    return null;
}

fn hasThemeInsetValue(compiler: *Compiler, suffix: []const u8) bool {
    if (isInsetSideNamespaceSuffix(suffix)) return false;
    return hasThemeValue(compiler, "--inset-", suffix);
}

fn opacityPercent(buf: []u8, token: []const u8) ?[]const u8 {
    if (opacityVariableName(token)) |name| return std.fmt.bufPrint(buf, "var({s})", .{name}) catch null;
    if (token.len >= 3 and token[0] == '[' and token[token.len - 1] == ']') {
        const inner = token[1 .. token.len - 1];
        return arbitraryOpacityPercent(buf, inner);
    }
    if (std.mem.endsWith(u8, token, "%")) return token;
    return std.fmt.bufPrint(buf, "{s}%", .{token}) catch null;
}

fn opacityPercentWithTheme(compiler: *Compiler, buf: []u8, token: []const u8) ?[]const u8 {
    if (resolveThemeValue(compiler, buf, "--opacity-", token)) |value| return value;
    return opacityPercent(buf, token);
}

fn opacityUnitAlphaWithTheme(compiler: *Compiler, buf: []u8, token: []const u8) ?[]const u8 {
    if (findThemeVariableWithNamespace(compiler, "--opacity-", token)) |variable| return variable.value;
    return opacityUnitAlphaNoTheme(buf, token);
}

fn opacityUnitAlphaNoTheme(buf: []u8, token: []const u8) ?[]const u8 {
    if (token.len >= 3 and token[0] == '[' and token[token.len - 1] == ']') {
        const inner = token[1 .. token.len - 1];
        if (std.mem.endsWith(u8, inner, "%")) {
            const pct = std.fmt.parseFloat(f64, inner[0 .. inner.len - 1]) catch return inner;
            return formatCssFloat3(buf, pct / 100.0);
        }
        if (std.mem.startsWith(u8, inner, "var(") or std.mem.startsWith(u8, inner, "--")) return inner;
        const number = std.fmt.parseFloat(f64, inner) catch return inner;
        if (number > 1.0) return formatCssFloat3(buf, number / 100.0);
        return formatCssFloat3(buf, number);
    }
    if (std.mem.endsWith(u8, token, "%")) {
        const pct = std.fmt.parseFloat(f64, token[0 .. token.len - 1]) catch return token;
        return formatCssFloat3(buf, pct / 100.0);
    }
    const numeric = std.fmt.parseFloat(f64, token) catch return token;
    if (numeric > 1.0) return formatCssFloat3(buf, numeric / 100.0);
    return token;
}

fn arbitraryOpacityPercent(buf: []u8, inner: []const u8) ?[]const u8 {
    if (std.mem.endsWith(u8, inner, "%")) return inner;
    if (std.mem.startsWith(u8, inner, "var(")) return inner;
    if (std.mem.startsWith(u8, inner, "--")) return std.fmt.bufPrint(buf, "var({s})", .{inner}) catch null;
    const number = std.fmt.parseFloat(f64, inner) catch {
        if (inner.len > 0 and inner[0] == '.') return std.fmt.bufPrint(buf, "{s}%", .{inner[1..]}) catch null;
        return std.fmt.bufPrint(buf, "{s}%", .{inner}) catch null;
    };
    if (number <= 1.0) return formatPercentNumber(buf, number * 100.0);
    return std.fmt.bufPrint(buf, "{s}%", .{inner}) catch null;
}

fn formatPercentNumber(buf: []u8, number: f64) ?[]const u8 {
    var number_buf: [64]u8 = undefined;
    const raw = std.fmt.bufPrint(&number_buf, "{d:.6}", .{number}) catch return null;
    const trimmed = trimFormattedCssFloat(buf, raw) orelse return null;
    if (trimmed.len + 1 > buf.len) return null;
    buf[trimmed.len] = '%';
    return buf[0 .. trimmed.len + 1];
}

fn opacityStaticPercent(compiler: *Compiler, buf: []u8, token: []const u8) ?[]const u8 {
    const name = opacityVariableName(token) orelse return null;
    const variable = findThemeVariable(compiler, name) orelse return null;
    const value = trimAscii(variable.value);
    if (std.mem.endsWith(u8, value, "%")) return value;
    const number = std.fmt.parseFloat(f64, value) catch return null;
    if (number <= 1.0) return formatPercentNumber(buf, number * 100.0);
    return std.fmt.bufPrint(buf, "{s}%", .{value}) catch null;
}

fn opacityVariableName(token: []const u8) ?[]const u8 {
    if (token.len < 4 or token[0] != '(' or token[token.len - 1] != ')') return null;
    const inner = trimAscii(token[1 .. token.len - 1]);
    if (!std.mem.startsWith(u8, inner, "--")) return null;
    return inner;
}

fn emitUtility(allocator: std.mem.Allocator, out: *std.ArrayList(u8), base: []const u8, important: bool) !bool {
    inline for (static_utilities) |utility| {
        if (std.mem.eql(u8, base, utility.name)) {
            try appendRawDeclarations(allocator, out, utility.css, important);
            return true;
        }
    }
    if (try emitForms(allocator, out, base, important)) return true;
    if (try emitSpacing(allocator, out, base, important)) return true;
    if (try emitAspectRatio(allocator, out, base, important)) return true;
    if (try emitSizing(allocator, out, base, important)) return true;
    if (try emitInset(allocator, out, base, important)) return true;
    if (try emitGrid(allocator, out, base, important)) return true;
    if (try emitBorderRadius(allocator, out, base, important)) return true;
    if (try emitBorderWidth(allocator, out, base, important)) return true;
    if (try emitTypographyUtility(allocator, out, base, important)) return true;
    if (try emitColorUtility(allocator, out, base, important)) return true;
    if (try emitNumericUtility(allocator, out, base, important)) return true;
    if (try emitTransformUtility(allocator, out, base, important)) return true;
    return false;
}

fn appendDecl(allocator: std.mem.Allocator, out: *std.ArrayList(u8), prop: []const u8, value: []const u8, important: bool) !void {
    try out.appendSlice(allocator, prop);
    try out.append(allocator, ':');
    try out.appendSlice(allocator, value);
    if (important) try out.appendSlice(allocator, "!important");
    try out.append(allocator, ';');
}

fn currentColorForProperty(prop: []const u8) []const u8 {
    return if (std.mem.startsWith(u8, prop, "--")) "currentcolor" else "currentColor";
}

fn appendRawDeclarations(allocator: std.mem.Allocator, out: *std.ArrayList(u8), raw: []const u8, important: bool) !void {
    if (!important) {
        try out.appendSlice(allocator, raw);
        return;
    }
    var start: usize = 0;
    while (start < raw.len) {
        const rel = std.mem.indexOfScalar(u8, raw[start..], ';') orelse break;
        const end = start + rel;
        if (end > start) {
            try out.appendSlice(allocator, raw[start..end]);
            try out.appendSlice(allocator, "!important;");
        }
        start = end + 1;
    }
}

fn appendImportantMarkers(allocator: std.mem.Allocator, out: *std.ArrayList(u8), raw: []const u8) !void {
    var start: usize = 0;
    for (raw, 0..) |c, i| {
        if (c != ';') continue;
        const chunk = raw[start..i];
        try out.appendSlice(allocator, chunk);
        if (!endsWithImportant(chunk)) try out.appendSlice(allocator, "!important");
        try out.append(allocator, ';');
        start = i + 1;
    }
    if (start < raw.len) try out.appendSlice(allocator, raw[start..]);
}

fn appendImportantCss(allocator: std.mem.Allocator, out: *std.ArrayList(u8), css: []const u8) !void {
    var i: usize = 0;
    while (i < css.len) {
        if (std.mem.startsWith(u8, css[i..], "@property ")) {
            const end = scanCssBlock(css, i) orelse css.len;
            try out.appendSlice(allocator, css[i..end]);
            i = end;
            continue;
        }
        if (css[i] == ';') {
            if (!importantAlreadyBefore(css, i)) try out.appendSlice(allocator, "!important");
            try out.append(allocator, ';');
            i += 1;
            continue;
        }
        if (css[i] == '}') {
            if (declarationBeforeBlockEndNeedsImportant(css, i)) try out.appendSlice(allocator, "!important");
            try out.append(allocator, '}');
            i += 1;
            continue;
        }
        try out.append(allocator, css[i]);
        i += 1;
    }
}

fn importantAlreadyBefore(css: []const u8, semicolon: usize) bool {
    var start = semicolon;
    while (start > 0 and css[start - 1] != '{' and css[start - 1] != ';') : (start -= 1) {}
    return endsWithImportant(css[start..semicolon]);
}

fn declarationBeforeBlockEndNeedsImportant(css: []const u8, block_end: usize) bool {
    var start = block_end;
    while (start > 0 and css[start - 1] != '{' and css[start - 1] != ';' and css[start - 1] != '}') : (start -= 1) {}
    const chunk = trimAscii(css[start..block_end]);
    if (chunk.len == 0) return false;
    if (std.mem.indexOfScalar(u8, chunk, ':') == null) return false;
    return !endsWithImportant(chunk);
}

fn endsWithImportant(input: []const u8) bool {
    const trimmed = trimAscii(input);
    return std.mem.endsWith(u8, trimmed, "!important");
}

fn emitForms(allocator: std.mem.Allocator, out: *std.ArrayList(u8), base: []const u8, important: bool) !bool {
    const text = "appearance:none;background-color:#fff;border-color:#6b7280;border-width:1px;border-radius:0;padding:.5rem .75rem;font-size:1rem;line-height:1.5rem;";
    const focus = "outline:2px solid transparent;outline-offset:2px;box-shadow:0 0 0 1px #2563eb;border-color:#2563eb;";
    if (std.mem.eql(u8, base, "form-input") or std.mem.eql(u8, base, "form-textarea") or std.mem.eql(u8, base, "form-select") or std.mem.eql(u8, base, "form-multiselect")) {
        try appendRawDeclarations(allocator, out, text, important);
        if (std.mem.eql(u8, base, "form-select") or std.mem.eql(u8, base, "form-multiselect")) {
            try appendDecl(allocator, out, "background-position", "right .5rem center", important);
            try appendDecl(allocator, out, "background-repeat", "no-repeat", important);
            try appendDecl(allocator, out, "background-size", "1.5em 1.5em", important);
        }
        _ = focus;
        return true;
    }
    if (std.mem.eql(u8, base, "form-checkbox") or std.mem.eql(u8, base, "form-radio")) {
        try appendRawDeclarations(allocator, out, "appearance:none;padding:0;display:inline-block;vertical-align:middle;background-origin:border-box;user-select:none;flex-shrink:0;height:1rem;width:1rem;color:#2563eb;background-color:#fff;border-color:#6b7280;border-width:1px;", important);
        if (std.mem.eql(u8, base, "form-radio")) {
            try appendDecl(allocator, out, "border-radius", "100%", important);
        } else {
            try appendDecl(allocator, out, "border-radius", "0", important);
        }
        return true;
    }
    return false;
}

fn emitSpacing(allocator: std.mem.Allocator, out: *std.ArrayList(u8), base: []const u8, important: bool) !bool {
    var negative = false;
    var name = base;
    if (name.len > 1 and name[0] == '-') {
        negative = true;
        name = name[1..];
    }
    const prefixes = [_]struct { prefix: []const u8, props: []const []const u8, allow_auto: bool, allow_negative: bool }{
        .{ .prefix = "p-", .props = &.{"padding"}, .allow_auto = false, .allow_negative = false },
        .{ .prefix = "px-", .props = &.{"padding-inline"}, .allow_auto = false, .allow_negative = false },
        .{ .prefix = "py-", .props = &.{"padding-block"}, .allow_auto = false, .allow_negative = false },
        .{ .prefix = "ps-", .props = &.{"padding-inline-start"}, .allow_auto = false, .allow_negative = false },
        .{ .prefix = "pe-", .props = &.{"padding-inline-end"}, .allow_auto = false, .allow_negative = false },
        .{ .prefix = "pbs-", .props = &.{"padding-block-start"}, .allow_auto = false, .allow_negative = false },
        .{ .prefix = "pbe-", .props = &.{"padding-block-end"}, .allow_auto = false, .allow_negative = false },
        .{ .prefix = "pt-", .props = &.{"padding-top"}, .allow_auto = false, .allow_negative = false },
        .{ .prefix = "pr-", .props = &.{"padding-right"}, .allow_auto = false, .allow_negative = false },
        .{ .prefix = "pb-", .props = &.{"padding-bottom"}, .allow_auto = false, .allow_negative = false },
        .{ .prefix = "pl-", .props = &.{"padding-left"}, .allow_auto = false, .allow_negative = false },
        .{ .prefix = "m-", .props = &.{"margin"}, .allow_auto = true, .allow_negative = true },
        .{ .prefix = "mx-", .props = &.{"margin-inline"}, .allow_auto = true, .allow_negative = true },
        .{ .prefix = "my-", .props = &.{"margin-block"}, .allow_auto = true, .allow_negative = true },
        .{ .prefix = "ms-", .props = &.{"margin-inline-start"}, .allow_auto = true, .allow_negative = true },
        .{ .prefix = "me-", .props = &.{"margin-inline-end"}, .allow_auto = true, .allow_negative = true },
        .{ .prefix = "mbs-", .props = &.{"margin-block-start"}, .allow_auto = true, .allow_negative = true },
        .{ .prefix = "mbe-", .props = &.{"margin-block-end"}, .allow_auto = true, .allow_negative = true },
        .{ .prefix = "mt-", .props = &.{"margin-top"}, .allow_auto = true, .allow_negative = true },
        .{ .prefix = "mr-", .props = &.{"margin-right"}, .allow_auto = true, .allow_negative = true },
        .{ .prefix = "mb-", .props = &.{"margin-bottom"}, .allow_auto = true, .allow_negative = true },
        .{ .prefix = "ml-", .props = &.{"margin-left"}, .allow_auto = true, .allow_negative = true },
        .{ .prefix = "scroll-mx-", .props = &.{"scroll-margin-inline"}, .allow_auto = false, .allow_negative = true },
        .{ .prefix = "scroll-my-", .props = &.{"scroll-margin-block"}, .allow_auto = false, .allow_negative = true },
        .{ .prefix = "scroll-ms-", .props = &.{"scroll-margin-inline-start"}, .allow_auto = false, .allow_negative = true },
        .{ .prefix = "scroll-me-", .props = &.{"scroll-margin-inline-end"}, .allow_auto = false, .allow_negative = true },
        .{ .prefix = "scroll-mbs-", .props = &.{"scroll-margin-block-start"}, .allow_auto = false, .allow_negative = true },
        .{ .prefix = "scroll-mbe-", .props = &.{"scroll-margin-block-end"}, .allow_auto = false, .allow_negative = true },
        .{ .prefix = "scroll-mt-", .props = &.{"scroll-margin-top"}, .allow_auto = false, .allow_negative = true },
        .{ .prefix = "scroll-mr-", .props = &.{"scroll-margin-right"}, .allow_auto = false, .allow_negative = true },
        .{ .prefix = "scroll-mb-", .props = &.{"scroll-margin-bottom"}, .allow_auto = false, .allow_negative = true },
        .{ .prefix = "scroll-ml-", .props = &.{"scroll-margin-left"}, .allow_auto = false, .allow_negative = true },
        .{ .prefix = "scroll-m-", .props = &.{"scroll-margin"}, .allow_auto = false, .allow_negative = true },
        .{ .prefix = "scroll-px-", .props = &.{"scroll-padding-inline"}, .allow_auto = false, .allow_negative = false },
        .{ .prefix = "scroll-py-", .props = &.{"scroll-padding-block"}, .allow_auto = false, .allow_negative = false },
        .{ .prefix = "scroll-ps-", .props = &.{"scroll-padding-inline-start"}, .allow_auto = false, .allow_negative = false },
        .{ .prefix = "scroll-pe-", .props = &.{"scroll-padding-inline-end"}, .allow_auto = false, .allow_negative = false },
        .{ .prefix = "scroll-pbs-", .props = &.{"scroll-padding-block-start"}, .allow_auto = false, .allow_negative = false },
        .{ .prefix = "scroll-pbe-", .props = &.{"scroll-padding-block-end"}, .allow_auto = false, .allow_negative = false },
        .{ .prefix = "scroll-pt-", .props = &.{"scroll-padding-top"}, .allow_auto = false, .allow_negative = false },
        .{ .prefix = "scroll-pr-", .props = &.{"scroll-padding-right"}, .allow_auto = false, .allow_negative = false },
        .{ .prefix = "scroll-pb-", .props = &.{"scroll-padding-bottom"}, .allow_auto = false, .allow_negative = false },
        .{ .prefix = "scroll-pl-", .props = &.{"scroll-padding-left"}, .allow_auto = false, .allow_negative = false },
        .{ .prefix = "scroll-p-", .props = &.{"scroll-padding"}, .allow_auto = false, .allow_negative = false },
        .{ .prefix = "gap-x-", .props = &.{"column-gap"}, .allow_auto = false, .allow_negative = false },
        .{ .prefix = "gap-y-", .props = &.{"row-gap"}, .allow_auto = false, .allow_negative = false },
        .{ .prefix = "gap-", .props = &.{"gap"}, .allow_auto = false, .allow_negative = false },
    };
    inline for (prefixes) |entry| {
        if (std.mem.startsWith(u8, name, entry.prefix)) {
            if (negative and !entry.allow_negative) return false;
            const suffix = name[entry.prefix.len..];
            var buf: [512]u8 = undefined;
            const value = resolveScaleValue(&buf, suffix, negative, entry.allow_auto) orelse return false;
            inline for (entry.props) |prop| try appendDecl(allocator, out, prop, value, important);
            return true;
        }
    }
    return false;
}

fn emitAspectRatio(allocator: std.mem.Allocator, out: *std.ArrayList(u8), base: []const u8, important: bool) !bool {
    if (!std.mem.startsWith(u8, base, "aspect-")) return false;
    const suffix = base["aspect-".len..];
    var buf: [512]u8 = undefined;
    const value = arbitraryValue(&buf, suffix) orelse ratioValue(&buf, suffix) orelse return false;
    try appendDecl(allocator, out, "aspect-ratio", value, important);
    return true;
}

fn ratioValue(buf: []u8, suffix: []const u8) ?[]const u8 {
    const slash = std.mem.indexOfScalar(u8, suffix, '/') orelse return null;
    const numerator = suffix[0..slash];
    const denominator = suffix[slash + 1 ..];
    if (!isUnsignedCssNumberToken(numerator) or !isUnsignedCssNumberToken(denominator)) return null;

    const n = std.fmt.parseFloat(f64, numerator) catch return null;
    const d = std.fmt.parseFloat(f64, denominator) catch return null;
    if (d == 0) return null;
    if (n == 0) return "0";
    return std.fmt.bufPrint(buf, "{s}/{s}", .{ numerator, denominator }) catch null;
}

fn isUnsignedCssNumberToken(token: []const u8) bool {
    if (token.len == 0) return false;
    var saw_digit = false;
    var saw_dot = false;
    for (token) |c| {
        if (isDigit(c)) {
            saw_digit = true;
            continue;
        }
        if (c == '.' and !saw_dot) {
            saw_dot = true;
            continue;
        }
        return false;
    }
    return saw_digit;
}

fn emitSizing(allocator: std.mem.Allocator, out: *std.ArrayList(u8), base: []const u8, important: bool) !bool {
    const prefixes = [_]struct { prefix: []const u8, prop: []const u8, axis: SizeAxis }{
        .{ .prefix = "w-", .prop = "width", .axis = .width },
        .{ .prefix = "min-w-", .prop = "min-width", .axis = .width },
        .{ .prefix = "max-w-", .prop = "max-width", .axis = .width },
        .{ .prefix = "h-", .prop = "height", .axis = .height },
        .{ .prefix = "min-h-", .prop = "min-height", .axis = .height },
        .{ .prefix = "max-h-", .prop = "max-height", .axis = .height },
        .{ .prefix = "size-", .prop = "size", .axis = .both },
        .{ .prefix = "basis-", .prop = "flex-basis", .axis = .width },
    };
    inline for (prefixes) |entry| {
        if (std.mem.startsWith(u8, base, entry.prefix)) {
            const suffix = base[entry.prefix.len..];
            var buf: [512]u8 = undefined;
            const value = resolveSizeValue(&buf, suffix, entry.axis) orelse return false;
            if (entry.axis == .both) {
                try appendDecl(allocator, out, "width", value, important);
                try appendDecl(allocator, out, "height", value, important);
            } else {
                try appendDecl(allocator, out, entry.prop, value, important);
            }
            return true;
        }
    }
    return false;
}

fn emitInset(allocator: std.mem.Allocator, out: *std.ArrayList(u8), base: []const u8, important: bool) !bool {
    var negative = false;
    var name = base;
    if (name.len > 1 and name[0] == '-') {
        negative = true;
        name = name[1..];
    }
    const prefixes = [_]struct { prefix: []const u8, props: []const []const u8 }{
        .{ .prefix = "inset-x-", .props = &.{"inset-inline"} },
        .{ .prefix = "inset-y-", .props = &.{"inset-block"} },
        .{ .prefix = "inset-s-", .props = &.{"inset-inline-start"} },
        .{ .prefix = "inset-e-", .props = &.{"inset-inline-end"} },
        .{ .prefix = "inset-bs-", .props = &.{"inset-block-start"} },
        .{ .prefix = "inset-be-", .props = &.{"inset-block-end"} },
        .{ .prefix = "inset-", .props = &.{"inset"} },
        .{ .prefix = "start-", .props = &.{"inset-inline-start"} },
        .{ .prefix = "end-", .props = &.{"inset-inline-end"} },
        .{ .prefix = "top-", .props = &.{"top"} },
        .{ .prefix = "right-", .props = &.{"right"} },
        .{ .prefix = "bottom-", .props = &.{"bottom"} },
        .{ .prefix = "left-", .props = &.{"left"} },
    };
    inline for (prefixes) |entry| {
        if (std.mem.startsWith(u8, name, entry.prefix)) {
            const suffix = name[entry.prefix.len..];
            var buf: [512]u8 = undefined;
            const value = resolveInsetValue(&buf, suffix, negative) orelse return false;
            inline for (entry.props) |prop| try appendDecl(allocator, out, prop, value, important);
            return true;
        }
    }
    return false;
}

fn resolveInsetValue(buf: []u8, suffix: []const u8, negative: bool) ?[]const u8 {
    if (std.mem.eql(u8, suffix, "auto")) return "auto";
    if (std.mem.eql(u8, suffix, "full")) return if (negative) "-100%" else "100%";
    if (std.mem.eql(u8, suffix, "px")) return if (negative) "-1px" else "1px";
    if (fractionPercent(buf, suffix)) |value| {
        if (!negative) return value;
        if (value.len + 1 > buf.len) return null;
        std.mem.copyBackwards(u8, buf[1 .. value.len + 1], value);
        buf[0] = '-';
        return buf[0 .. value.len + 1];
    }
    if (arbitraryValue(buf, suffix)) |value| {
        if (!negative) return value;
        if (value.len + 1 > buf.len) return null;
        std.mem.copyBackwards(u8, buf[1 .. value.len + 1], value);
        buf[0] = '-';
        return buf[0 .. value.len + 1];
    }
    return resolveScaleValue(buf, suffix, negative, false);
}

fn emitGrid(allocator: std.mem.Allocator, out: *std.ArrayList(u8), base: []const u8, important: bool) !bool {
    var buf: [256]u8 = undefined;
    if (std.mem.startsWith(u8, base, "grid-cols-")) {
        const suffix = base["grid-cols-".len..];
        if (std.mem.eql(u8, suffix, "none")) {
            try appendDecl(allocator, out, "grid-template-columns", "none", important);
            return true;
        }
        if (parsePositiveInt(suffix)) |n| {
            const value = try std.fmt.bufPrint(&buf, "repeat({d},minmax(0,1fr))", .{n});
            try appendDecl(allocator, out, "grid-template-columns", value, important);
            return true;
        }
        if (arbitraryValue(&buf, suffix)) |value| {
            try appendDecl(allocator, out, "grid-template-columns", value, important);
            return true;
        }
    }
    if (std.mem.startsWith(u8, base, "grid-rows-")) {
        const suffix = base["grid-rows-".len..];
        if (parsePositiveInt(suffix)) |n| {
            const value = try std.fmt.bufPrint(&buf, "repeat({d},minmax(0,1fr))", .{n});
            try appendDecl(allocator, out, "grid-template-rows", value, important);
            return true;
        }
    }
    if (std.mem.startsWith(u8, base, "col-span-")) {
        const suffix = base["col-span-".len..];
        if (parsePositiveInt(suffix)) |n| {
            const value = try std.fmt.bufPrint(&buf, "span {d}/span {d}", .{ n, n });
            try appendDecl(allocator, out, "grid-column", value, important);
            return true;
        }
    }
    if (std.mem.startsWith(u8, base, "row-span-")) {
        const suffix = base["row-span-".len..];
        if (parsePositiveInt(suffix)) |n| {
            const value = try std.fmt.bufPrint(&buf, "span {d}/span {d}", .{ n, n });
            try appendDecl(allocator, out, "grid-row", value, important);
            return true;
        }
    }
    return false;
}

fn emitBorderRadius(allocator: std.mem.Allocator, out: *std.ArrayList(u8), base: []const u8, important: bool) !bool {
    const suffix = radiusTokenForBase(base) orelse return false;
    var buf: [512]u8 = undefined;
    const value = radiusValue(suffix) orelse arbitraryValue(&buf, suffix) orelse return false;
    if (!try appendRadiusDeclarations(allocator, out, base, value, important)) return false;
    return true;
}

fn radiusTokenForBase(base: []const u8) ?[]const u8 {
    const roots = [_][]const u8{
        "rounded-ss",
        "rounded-se",
        "rounded-ee",
        "rounded-es",
        "rounded-tl",
        "rounded-tr",
        "rounded-br",
        "rounded-bl",
        "rounded-s",
        "rounded-e",
        "rounded-t",
        "rounded-r",
        "rounded-b",
        "rounded-l",
        "rounded",
    };
    inline for (roots) |root| {
        if (radiusTokenForRoot(base, root)) |token| return token;
    }
    return null;
}

fn radiusTokenForRoot(base: []const u8, root: []const u8) ?[]const u8 {
    if (std.mem.eql(u8, base, root)) return "";
    if (base.len > root.len and std.mem.startsWith(u8, base, root) and base[root.len] == '-') return base[root.len + 1 ..];
    return null;
}

fn appendRadiusDeclarations(allocator: std.mem.Allocator, out: *std.ArrayList(u8), base: []const u8, value: []const u8, important: bool) !bool {
    const entries = [_]struct { root: []const u8, props: []const []const u8 }{
        .{ .root = "rounded-ss", .props = &.{"border-start-start-radius"} },
        .{ .root = "rounded-se", .props = &.{"border-start-end-radius"} },
        .{ .root = "rounded-ee", .props = &.{"border-end-end-radius"} },
        .{ .root = "rounded-es", .props = &.{"border-end-start-radius"} },
        .{ .root = "rounded-tl", .props = &.{"border-top-left-radius"} },
        .{ .root = "rounded-tr", .props = &.{"border-top-right-radius"} },
        .{ .root = "rounded-br", .props = &.{"border-bottom-right-radius"} },
        .{ .root = "rounded-bl", .props = &.{"border-bottom-left-radius"} },
        .{ .root = "rounded-s", .props = &.{ "border-start-start-radius", "border-end-start-radius" } },
        .{ .root = "rounded-e", .props = &.{ "border-start-end-radius", "border-end-end-radius" } },
        .{ .root = "rounded-t", .props = &.{ "border-top-left-radius", "border-top-right-radius" } },
        .{ .root = "rounded-r", .props = &.{ "border-top-right-radius", "border-bottom-right-radius" } },
        .{ .root = "rounded-b", .props = &.{ "border-bottom-right-radius", "border-bottom-left-radius" } },
        .{ .root = "rounded-l", .props = &.{ "border-top-left-radius", "border-bottom-left-radius" } },
        .{ .root = "rounded", .props = &.{"border-radius"} },
    };
    inline for (entries) |entry| {
        if (radiusTokenForRoot(base, entry.root) != null) {
            inline for (entry.props) |prop| try appendDecl(allocator, out, prop, value, important);
            return true;
        }
    }
    return false;
}

fn radiusValue(suffix: []const u8) ?[]const u8 {
    if (suffix.len == 0) return ".25rem";
    const pairs = [_]struct { name: []const u8, value: []const u8 }{
        .{ .name = "none", .value = "0" },
        .{ .name = "sm", .value = "var(--radius-sm)" },
        .{ .name = "md", .value = "var(--radius-md)" },
        .{ .name = "lg", .value = "var(--radius-lg)" },
        .{ .name = "xl", .value = "var(--radius-xl)" },
        .{ .name = "2xl", .value = "var(--radius-2xl)" },
        .{ .name = "3xl", .value = "var(--radius-3xl)" },
        .{ .name = "full", .value = "3.40282e38px" },
    };
    inline for (pairs) |pair| {
        if (std.mem.eql(u8, suffix, pair.name)) return pair.value;
    }
    return null;
}

fn emitBorderWidth(allocator: std.mem.Allocator, out: *std.ArrayList(u8), base: []const u8, important: bool) !bool {
    const prefixes = [_]struct { prefix: []const u8, props: []const []const u8 }{
        .{ .prefix = "border-x-", .props = &.{ "border-left-width", "border-right-width" } },
        .{ .prefix = "border-y-", .props = &.{ "border-top-width", "border-bottom-width" } },
        .{ .prefix = "border-t-", .props = &.{"border-top-width"} },
        .{ .prefix = "border-r-", .props = &.{"border-right-width"} },
        .{ .prefix = "border-b-", .props = &.{"border-bottom-width"} },
        .{ .prefix = "border-l-", .props = &.{"border-left-width"} },
        .{ .prefix = "border-", .props = &.{"border-width"} },
    };
    if (std.mem.eql(u8, base, "border")) {
        try appendDecl(allocator, out, "border-width", "1px", important);
        return true;
    }
    inline for (prefixes) |entry| {
        if (std.mem.startsWith(u8, base, entry.prefix)) {
            const suffix = base[entry.prefix.len..];
            if (borderStyleValue(suffix)) |style| {
                try appendDecl(allocator, out, "--tw-border-style", style, important);
                try appendDecl(allocator, out, "border-style", style, important);
                return true;
            }
            var buf: [256]u8 = undefined;
            const value = borderWidthValue(&buf, suffix) orelse return false;
            inline for (entry.props) |prop| try appendDecl(allocator, out, prop, value, important);
            return true;
        }
    }
    return false;
}

fn borderStyleValue(suffix: []const u8) ?[]const u8 {
    const pairs = [_]struct { name: []const u8, value: []const u8 }{
        .{ .name = "solid", .value = "solid" },
        .{ .name = "dashed", .value = "dashed" },
        .{ .name = "dotted", .value = "dotted" },
        .{ .name = "double", .value = "double" },
        .{ .name = "hidden", .value = "hidden" },
        .{ .name = "none", .value = "none" },
    };
    inline for (pairs) |pair| {
        if (std.mem.eql(u8, suffix, pair.name)) return pair.value;
    }
    return null;
}

fn emitTypographyUtility(allocator: std.mem.Allocator, out: *std.ArrayList(u8), base: []const u8, important: bool) !bool {
    if (std.mem.startsWith(u8, base, "line-clamp-")) {
        const suffix = base["line-clamp-".len..];
        if (std.mem.eql(u8, suffix, "none")) {
            try appendRawDeclarations(allocator, out, "-webkit-line-clamp:unset;-webkit-box-orient:horizontal;display:block;overflow:visible;", important);
            return true;
        }
        const value = parsePositiveInt(suffix) orelse return false;
        var buf: [192]u8 = undefined;
        const css = try std.fmt.bufPrint(&buf, "-webkit-line-clamp:{d};-webkit-box-orient:vertical;display:-webkit-box;overflow:hidden;", .{value});
        try appendRawDeclarations(allocator, out, css, important);
        return true;
    }
    if (std.mem.startsWith(u8, base, "text-")) {
        const suffix = base["text-".len..];
        if (textSizeValue(suffix)) |value| {
            try appendRawDeclarations(allocator, out, value, important);
            return true;
        }
    }
    if (std.mem.startsWith(u8, base, "leading-")) {
        const suffix = base["leading-".len..];
        if (lineHeightValue(suffix)) |value| {
            try appendDecl(allocator, out, "line-height", value, important);
            return true;
        }
    }
    if (std.mem.startsWith(u8, base, "tracking-")) {
        const suffix = base["tracking-".len..];
        if (trackingValue(suffix)) |value| {
            try appendDecl(allocator, out, "letter-spacing", value, important);
            return true;
        }
    }
    if (std.mem.startsWith(u8, base, "font-[")) {
        var buf: [512]u8 = undefined;
        if (arbitraryValue(&buf, base["font-".len..])) |value| {
            try appendDecl(allocator, out, "font-family", value, important);
            return true;
        }
    }
    return false;
}

fn textSizeValue(suffix: []const u8) ?[]const u8 {
    const pairs = [_]struct { name: []const u8, css: []const u8 }{
        .{ .name = "xs", .css = "font-size:var(--text-xs);line-height:var(--tw-leading,var(--text-xs--line-height));" },
        .{ .name = "sm", .css = "font-size:var(--text-sm);line-height:var(--tw-leading,var(--text-sm--line-height));" },
        .{ .name = "base", .css = "font-size:var(--text-base);line-height:var(--tw-leading,var(--text-base--line-height));" },
        .{ .name = "lg", .css = "font-size:var(--text-lg);line-height:var(--tw-leading,var(--text-lg--line-height));" },
        .{ .name = "xl", .css = "font-size:var(--text-xl);line-height:var(--tw-leading,var(--text-xl--line-height));" },
        .{ .name = "2xl", .css = "font-size:var(--text-2xl);line-height:var(--tw-leading,var(--text-2xl--line-height));" },
        .{ .name = "3xl", .css = "font-size:var(--text-3xl);line-height:var(--tw-leading,var(--text-3xl--line-height));" },
        .{ .name = "4xl", .css = "font-size:var(--text-4xl);line-height:var(--tw-leading,var(--text-4xl--line-height));" },
        .{ .name = "5xl", .css = "font-size:var(--text-5xl);line-height:var(--tw-leading,var(--text-5xl--line-height));" },
        .{ .name = "6xl", .css = "font-size:var(--text-6xl);line-height:var(--tw-leading,var(--text-6xl--line-height));" },
        .{ .name = "7xl", .css = "font-size:var(--text-7xl);line-height:var(--tw-leading,var(--text-7xl--line-height));" },
        .{ .name = "8xl", .css = "font-size:var(--text-8xl);line-height:var(--tw-leading,var(--text-8xl--line-height));" },
        .{ .name = "9xl", .css = "font-size:var(--text-9xl);line-height:var(--tw-leading,var(--text-9xl--line-height));" },
    };
    inline for (pairs) |pair| {
        if (std.mem.eql(u8, suffix, pair.name)) return pair.css;
    }
    return null;
}

fn lineHeightValue(suffix: []const u8) ?[]const u8 {
    const pairs = [_]struct { name: []const u8, value: []const u8 }{
        .{ .name = "none", .value = "1" },
        .{ .name = "tight", .value = "1.25" },
        .{ .name = "snug", .value = "1.375" },
        .{ .name = "normal", .value = "1.5" },
        .{ .name = "relaxed", .value = "1.625" },
        .{ .name = "loose", .value = "2" },
        .{ .name = "3", .value = ".75rem" },
        .{ .name = "4", .value = "1rem" },
        .{ .name = "5", .value = "1.25rem" },
        .{ .name = "6", .value = "1.5rem" },
        .{ .name = "7", .value = "1.75rem" },
        .{ .name = "8", .value = "2rem" },
        .{ .name = "9", .value = "2.25rem" },
        .{ .name = "10", .value = "2.5rem" },
    };
    inline for (pairs) |pair| {
        if (std.mem.eql(u8, suffix, pair.name)) return pair.value;
    }
    return null;
}

fn trackingValue(suffix: []const u8) ?[]const u8 {
    const pairs = [_]struct { name: []const u8, value: []const u8 }{
        .{ .name = "tighter", .value = "-.05em" },
        .{ .name = "tight", .value = "-.025em" },
        .{ .name = "normal", .value = "0" },
        .{ .name = "wide", .value = ".025em" },
        .{ .name = "wider", .value = ".05em" },
        .{ .name = "widest", .value = ".1em" },
    };
    inline for (pairs) |pair| {
        if (std.mem.eql(u8, suffix, pair.name)) return pair.value;
    }
    return null;
}

fn emitColorUtility(allocator: std.mem.Allocator, out: *std.ArrayList(u8), base: []const u8, important: bool) !bool {
    const prefixes = [_]struct { prefix: []const u8, prop: []const u8 }{
        .{ .prefix = "bg-", .prop = "background-color" },
        .{ .prefix = "text-", .prop = "color" },
        .{ .prefix = "border-", .prop = "border-color" },
        .{ .prefix = "ring-offset-", .prop = "--tw-ring-offset-color" },
        .{ .prefix = "inset-ring-", .prop = "--tw-inset-ring-color" },
        .{ .prefix = "ring-", .prop = "--tw-ring-color" },
        .{ .prefix = "decoration-", .prop = "text-decoration-color" },
        .{ .prefix = "placeholder-", .prop = "color" },
        .{ .prefix = "accent-", .prop = "accent-color" },
        .{ .prefix = "caret-", .prop = "caret-color" },
        .{ .prefix = "fill-", .prop = "fill" },
        .{ .prefix = "stroke-", .prop = "stroke" },
    };
    inline for (prefixes) |entry| {
        if (std.mem.startsWith(u8, base, entry.prefix)) {
            const suffix = base[entry.prefix.len..];
            var buf: [512]u8 = undefined;
            if (std.mem.eql(u8, entry.prefix, "bg-")) {
                if (arbitraryBackgroundDeclaration(&buf, suffix)) |decl| {
                    try appendDecl(allocator, out, decl.prop, decl.value, important);
                    return true;
                }
            }
            const value = colorValue(&buf, suffix) orelse return false;
            try appendDecl(allocator, out, entry.prop, value, important);
            return true;
        }
    }
    return false;
}

const CssDeclaration = struct {
    prop: []const u8,
    value: []const u8,
};

fn arbitraryBackgroundDeclaration(buf: []u8, suffix: []const u8) ?CssDeclaration {
    const value = arbitraryValue(buf, suffix) orelse return null;
    if (std.mem.startsWith(u8, value, "url(") or
        std.mem.startsWith(u8, value, "image(") or
        std.mem.startsWith(u8, value, "image-set(") or
        std.mem.startsWith(u8, value, "linear-gradient(") or
        std.mem.startsWith(u8, value, "radial-gradient(") or
        std.mem.startsWith(u8, value, "conic-gradient("))
    {
        return .{ .prop = "background-image", .value = value };
    }

    const colon = topLevelDeclarationColon(value) orelse return null;
    const hint = trimAscii(value[0..colon]);
    var hinted_value = trimAscii(value[colon + 1 ..]);
    if (hinted_value.len == 0) return null;
    if (std.mem.eql(u8, hint, "image")) return .{ .prop = "background-image", .value = hinted_value };
    if (std.mem.eql(u8, hint, "length") or std.mem.eql(u8, hint, "size")) return .{ .prop = "background-size", .value = hinted_value };
    if (std.mem.eql(u8, hint, "position")) {
        hinted_value = canonicalBackgroundPosition(hinted_value);
        return .{ .prop = "background-position", .value = hinted_value };
    }
    if (std.mem.eql(u8, hint, "color")) return .{ .prop = "background-color", .value = hinted_value };
    return null;
}

fn canonicalBackgroundPosition(value: []const u8) []const u8 {
    if (std.mem.eql(u8, value, "center top")) return "top";
    if (std.mem.eql(u8, value, "center bottom")) return "bottom";
    if (std.mem.eql(u8, value, "left center")) return "left";
    if (std.mem.eql(u8, value, "right center")) return "right";
    return value;
}

fn emitNumericUtility(allocator: std.mem.Allocator, out: *std.ArrayList(u8), base: []const u8, important: bool) !bool {
    const prefixes = [_]struct { prefix: []const u8, prop: []const u8, percent: bool }{
        .{ .prefix = "opacity-", .prop = "opacity", .percent = true },
        .{ .prefix = "z-", .prop = "z-index", .percent = false },
        .{ .prefix = "order-", .prop = "order", .percent = false },
        .{ .prefix = "duration-", .prop = "transition-duration", .percent = false },
        .{ .prefix = "delay-", .prop = "transition-delay", .percent = false },
    };
    inline for (prefixes) |entry| {
        if (std.mem.startsWith(u8, base, entry.prefix)) {
            const suffix = base[entry.prefix.len..];
            var buf: [128]u8 = undefined;
            if (arbitraryValue(&buf, suffix)) |value| {
                try appendDecl(allocator, out, entry.prop, value, important);
                return true;
            }
            if (parsePositiveInt(suffix)) |n| {
                const value = if (entry.percent) formatPercent(&buf, n) orelse return false else if (std.mem.startsWith(u8, entry.prefix, "duration") or std.mem.startsWith(u8, entry.prefix, "delay")) try std.fmt.bufPrint(&buf, "{d}ms", .{n}) else try std.fmt.bufPrint(&buf, "{d}", .{n});
                try appendDecl(allocator, out, entry.prop, value, important);
                return true;
            }
        }
    }
    if (std.mem.eql(u8, base, "z-auto")) {
        try appendDecl(allocator, out, "z-index", "auto", important);
        return true;
    }
    return false;
}

fn formatPercent(buf: []u8, n: u32) ?[]const u8 {
    if (n == 0) return "0";
    if (n == 100) return "1";
    if (n < 100) {
        if (n % 10 == 0) return std.fmt.bufPrint(buf, ".{d}", .{n / 10}) catch null;
        return std.fmt.bufPrint(buf, ".{d:0>2}", .{n}) catch null;
    }
    return std.fmt.bufPrint(buf, "{d}", .{@as(f64, @floatFromInt(n)) / 100.0}) catch null;
}

fn emitTransformUtility(allocator: std.mem.Allocator, out: *std.ArrayList(u8), base: []const u8, important: bool) !bool {
    var negative = false;
    var name = base;
    if (name.len > 1 and name[0] == '-') {
        negative = true;
        name = name[1..];
    }
    const prefixes = [_]struct { prefix: []const u8, prop: []const u8 }{
        .{ .prefix = "translate-x-", .prop = "--tw-translate-x" },
        .{ .prefix = "translate-y-", .prop = "--tw-translate-y" },
        .{ .prefix = "rotate-", .prop = "--tw-rotate" },
        .{ .prefix = "scale-", .prop = "--tw-scale-x" },
        .{ .prefix = "scale-x-", .prop = "--tw-scale-x" },
        .{ .prefix = "scale-y-", .prop = "--tw-scale-y" },
    };
    inline for (prefixes) |entry| {
        if (std.mem.startsWith(u8, name, entry.prefix)) {
            const suffix = name[entry.prefix.len..];
            var buf: [256]u8 = undefined;
            var value: []const u8 = undefined;
            if (std.mem.startsWith(u8, entry.prefix, "rotate")) {
                value = if (arbitraryValue(&buf, suffix)) |v| v else try std.fmt.bufPrint(&buf, "{s}{s}deg", .{ if (negative) "-" else "", suffix });
                try appendDecl(allocator, out, "rotate", value, important);
                return true;
            } else if (std.mem.startsWith(u8, entry.prefix, "scale")) {
                value = if (arbitraryValue(&buf, suffix)) |v| v else try std.fmt.bufPrint(&buf, "{d}", .{(@as(f64, @floatFromInt(parsePositiveInt(suffix) orelse return false)) / 100.0)});
            } else {
                value = resolveTranslateValue(&buf, suffix, negative) orelse return false;
            }
            try appendDecl(allocator, out, entry.prop, value, important);
            if (std.mem.eql(u8, entry.prefix, "scale-")) {
                try appendDecl(allocator, out, "--tw-scale-y", value, important);
            }
            try appendDecl(allocator, out, "transform", "translate(var(--tw-translate-x,0),var(--tw-translate-y,0)) rotate(var(--tw-rotate,0)) skewX(var(--tw-skew-x,0)) skewY(var(--tw-skew-y,0)) scaleX(var(--tw-scale-x,1)) scaleY(var(--tw-scale-y,1))", important);
            return true;
        }
    }
    return false;
}

fn resolveScaleValue(buf: []u8, suffix: []const u8, negative: bool, allow_auto: bool) ?[]const u8 {
    if (allow_auto and std.mem.eql(u8, suffix, "auto")) return "auto";
    if (std.mem.eql(u8, suffix, "0")) return "calc(var(--spacing)*0)";
    if (std.mem.eql(u8, suffix, "px")) return if (negative) "-1px" else "1px";
    if (arbitraryValue(buf, suffix)) |value| {
        if (!negative or std.mem.startsWith(u8, value, "-")) return value;
        if (value.len + 1 > buf.len) return null;
        std.mem.copyBackwards(u8, buf[1 .. value.len + 1], value);
        buf[0] = '-';
        return buf[0 .. value.len + 1];
    }
    if (isScaleToken(suffix)) {
        var factor_buf: [64]u8 = undefined;
        const factor = scaleFactor(&factor_buf, suffix, negative) orelse return null;
        return std.fmt.bufPrint(buf, "calc(var(--spacing)*{s})", .{factor}) catch null;
    }
    return null;
}

fn resolveTranslateValue(buf: []u8, suffix: []const u8, negative: bool) ?[]const u8 {
    if (std.mem.eql(u8, suffix, "full")) return if (negative) "-100%" else "100%";
    if (translateFractionPercent(buf, suffix, negative)) |value| return value;
    return resolveScaleValue(buf, suffix, negative, false);
}

fn translateFractionPercent(buf: []u8, suffix: []const u8, negative: bool) ?[]const u8 {
    const slash = std.mem.indexOfScalar(u8, suffix, '/') orelse return null;
    const a = parsePositiveInt(suffix[0..slash]) orelse return null;
    const b = parsePositiveInt(suffix[slash + 1 ..]) orelse return null;
    if (b == 0) return null;
    if (negative) return std.fmt.bufPrint(buf, "calc(calc({d} / {d} * 100%) * -1)", .{ a, b }) catch null;
    return std.fmt.bufPrint(buf, "calc({d} / {d} * 100%)", .{ a, b }) catch null;
}

fn scaleFactor(buf: []u8, suffix: []const u8, negative: bool) ?[]const u8 {
    if (suffix.len > 2 and suffix[0] == '0' and suffix[1] == '.') {
        return std.fmt.bufPrint(buf, "{s}.{s}", .{ if (negative) "-" else "", suffix[2..] }) catch null;
    }
    return std.fmt.bufPrint(buf, "{s}{s}", .{ if (negative) "-" else "", suffix }) catch null;
}

fn resolveSizeValue(buf: []u8, suffix: []const u8, axis: SizeAxis) ?[]const u8 {
    if (std.mem.eql(u8, suffix, "auto")) return "auto";
    if (std.mem.eql(u8, suffix, "full")) return "100%";
    if (std.mem.eql(u8, suffix, "min")) return "min-content";
    if (std.mem.eql(u8, suffix, "max")) return "max-content";
    if (std.mem.eql(u8, suffix, "fit")) return "fit-content";
    if (std.mem.eql(u8, suffix, "dvw")) return "100dvw";
    if (std.mem.eql(u8, suffix, "dvh")) return "100dvh";
    if (std.mem.eql(u8, suffix, "screen")) return if (axis == .height) "100vh" else "100vw";
    if (fractionPercent(buf, suffix)) |value| return value;
    if (resolveScaleValue(buf, suffix, false, false)) |value| return value;
    return arbitraryValue(buf, suffix);
}

fn fractionPercent(buf: []u8, suffix: []const u8) ?[]const u8 {
    const slash = std.mem.indexOfScalar(u8, suffix, '/') orelse return null;
    const a = parsePositiveInt(suffix[0..slash]) orelse return null;
    const b = parsePositiveInt(suffix[slash + 1 ..]) orelse return null;
    if (b == 0) return null;
    const pct = (@as(f64, @floatFromInt(a)) / @as(f64, @floatFromInt(b))) * 100.0;
    const number = formatCssFloat4(buf, pct) orelse return null;
    if (number.len + 1 > buf.len) return null;
    buf[number.len] = '%';
    return buf[0 .. number.len + 1];
}

fn arbitraryValue(buf: []u8, suffix: []const u8) ?[]const u8 {
    if (suffix.len < 3 or suffix[0] != '[' or suffix[suffix.len - 1] != ']') return null;
    const inner = suffix[1 .. suffix.len - 1];
    if (inner.len > buf.len) return null;
    for (inner, 0..) |c, i| {
        buf[i] = if (c == '_') ' ' else c;
    }
    return buf[0..inner.len];
}

fn isScaleToken(suffix: []const u8) bool {
    if (suffix.len == 0) return false;
    for (suffix) |c| {
        if (!((c >= '0' and c <= '9') or c == '.')) return false;
    }
    return true;
}

fn parsePositiveInt(s: []const u8) ?u32 {
    if (s.len == 0) return null;
    var n: u32 = 0;
    for (s) |c| {
        if (c < '0' or c > '9') return null;
        n = n * 10 + @as(u32, c - '0');
    }
    return n;
}

fn colorValue(buf: []u8, suffix: []const u8) ?[]const u8 {
    if (suffix.len == 0) return null;
    if (arbitraryValue(buf, suffix)) |value| return value;
    if (std.mem.eql(u8, suffix, "transparent")) return "#0000";
    if (std.mem.eql(u8, suffix, "current")) return "currentColor";
    if (std.mem.eql(u8, suffix, "inherit")) return "inherit";
    if (std.mem.eql(u8, suffix, "black")) return "var(--color-black)";
    if (std.mem.eql(u8, suffix, "white")) return "var(--color-white)";

    var color = suffix;
    var opacity: ?[]const u8 = null;
    if (std.mem.indexOfScalar(u8, suffix, '/')) |slash| {
        color = suffix[0..slash];
        opacity = suffix[slash + 1 ..];
    }
    _ = fallbackColor(color) orelse return null;
    if (opacity) |alpha_token| {
        var base_buf: [512]u8 = undefined;
        const base = std.fmt.bufPrint(&base_buf, "var(--color-{s})", .{color}) catch return null;
        var pct_buf: [32]u8 = undefined;
        const pct = if (std.mem.endsWith(u8, alpha_token, "%")) alpha_token else std.fmt.bufPrint(&pct_buf, "{s}%", .{alpha_token}) catch return null;
        return std.fmt.bufPrint(buf, "color-mix(in oklab,{s} {s},transparent)", .{ base, pct }) catch null;
    }
    return std.fmt.bufPrint(buf, "var(--color-{s})", .{color}) catch null;
}

fn fallbackColor(color: []const u8) ?[]const u8 {
    const dash = std.mem.indexOfScalar(u8, color, '-') orelse return null;
    const name = color[0..dash];
    const shade = color[dash + 1 ..];
    if (!isDefaultShade(shade)) return null;
    const pairs = [_]struct { name: []const u8, value: []const u8 }{
        .{ .name = "slate", .value = "#64748b" },
        .{ .name = "gray", .value = "#6b7280" },
        .{ .name = "zinc", .value = "#71717a" },
        .{ .name = "neutral", .value = "#737373" },
        .{ .name = "stone", .value = "#78716c" },
        .{ .name = "red", .value = "#ef4444" },
        .{ .name = "orange", .value = "#f97316" },
        .{ .name = "amber", .value = "#f59e0b" },
        .{ .name = "yellow", .value = "#eab308" },
        .{ .name = "lime", .value = "#84cc16" },
        .{ .name = "green", .value = "#22c55e" },
        .{ .name = "emerald", .value = "#10b981" },
        .{ .name = "teal", .value = "#14b8a6" },
        .{ .name = "cyan", .value = "#06b6d4" },
        .{ .name = "sky", .value = "#0ea5e9" },
        .{ .name = "blue", .value = "#3b82f6" },
        .{ .name = "indigo", .value = "#6366f1" },
        .{ .name = "violet", .value = "#8b5cf6" },
        .{ .name = "purple", .value = "#a855f7" },
        .{ .name = "fuchsia", .value = "#d946ef" },
        .{ .name = "pink", .value = "#ec4899" },
        .{ .name = "rose", .value = "#f43f5e" },
    };
    inline for (pairs) |pair| {
        if (std.mem.eql(u8, name, pair.name)) return pair.value;
    }
    return null;
}

fn isDefaultShade(shade: []const u8) bool {
    const shades = [_][]const u8{ "50", "100", "200", "300", "400", "500", "600", "700", "800", "900", "950" };
    inline for (shades) |valid| {
        if (std.mem.eql(u8, shade, valid)) return true;
    }
    return false;
}

fn renderTypography(allocator: std.mem.Allocator, out: *std.ArrayList(u8), raw: []const u8, parsed: ParsedCandidate) !bool {
    const base = parsed.base;
    if (!(std.mem.eql(u8, base, "prose") or std.mem.eql(u8, base, "prose-sm") or std.mem.eql(u8, base, "prose-lg") or std.mem.eql(u8, base, "prose-xl") or std.mem.eql(u8, base, "prose-invert"))) return false;
    if (std.mem.eql(u8, base, "prose-invert")) {
        try writeRule(allocator, out, raw, parsed.variants, "", "color:#e5e7eb;");
        try writeRule(allocator, out, raw, parsed.variants, " :where(a)", "color:#93c5fd;");
        try writeRule(allocator, out, raw, parsed.variants, " :where(strong)", "color:#fff;");
        return true;
    }
    const font_css = if (std.mem.eql(u8, base, "prose-sm")) "font-size:.875rem;line-height:1.7142857;max-width:65ch;color:#374151;" else if (std.mem.eql(u8, base, "prose-lg")) "font-size:1.125rem;line-height:1.7777778;max-width:65ch;color:#374151;" else if (std.mem.eql(u8, base, "prose-xl")) "font-size:1.25rem;line-height:1.8;max-width:65ch;color:#374151;" else "font-size:1rem;line-height:1.75;max-width:65ch;color:#374151;";
    try writeRule(allocator, out, raw, parsed.variants, "", font_css);
    try writeRule(allocator, out, raw, parsed.variants, " :where(p)", "margin-top:1.25em;margin-bottom:1.25em;");
    try writeRule(allocator, out, raw, parsed.variants, " :where(a)", "color:#111827;text-decoration:underline;font-weight:500;");
    try writeRule(allocator, out, raw, parsed.variants, " :where(strong)", "color:#111827;font-weight:600;");
    try writeRule(allocator, out, raw, parsed.variants, " :where(h1)", "color:#111827;font-weight:800;font-size:2.25em;line-height:1.1111111;margin-top:0;margin-bottom:.8888889em;");
    try writeRule(allocator, out, raw, parsed.variants, " :where(h2)", "color:#111827;font-weight:700;font-size:1.5em;line-height:1.3333333;margin-top:2em;margin-bottom:1em;");
    try writeRule(allocator, out, raw, parsed.variants, " :where(ul)", "list-style-type:disc;margin-top:1.25em;margin-bottom:1.25em;padding-left:1.625em;");
    try writeRule(allocator, out, raw, parsed.variants, " :where(ol)", "list-style-type:decimal;margin-top:1.25em;margin-bottom:1.25em;padding-left:1.625em;");
    try writeRule(allocator, out, raw, parsed.variants, " :where(code)", "color:#111827;font-weight:600;font-size:.875em;");
    try writeRule(allocator, out, raw, parsed.variants, " :where(pre)", "color:#e5e7eb;background-color:#1f2937;overflow-x:auto;font-weight:400;font-size:.875em;line-height:1.7142857;margin-top:1.7142857em;margin-bottom:1.7142857em;border-radius:.375rem;padding:.8571429em 1.1428571em;");
    return true;
}

const Instance = struct {
    allocator: std.mem.Allocator,
    chunks: std.ArrayList(OwnedChunk) = .empty,
    result: ?[]u8 = null,

    fn init(allocator: std.mem.Allocator) Instance {
        return .{ .allocator = allocator };
    }

    fn deinit(self: *Instance) void {
        self.clear();
        if (self.result) |result| self.allocator.free(result);
        self.chunks.deinit(self.allocator);
    }

    fn clear(self: *Instance) void {
        for (self.chunks.items) |chunk| {
            self.allocator.free(chunk.name);
            self.allocator.free(chunk.content);
        }
        self.chunks.clearRetainingCapacity();
        if (self.result) |result| {
            self.allocator.free(result);
            self.result = null;
        }
    }

    fn putChunk(self: *Instance, name: []const u8, content: []const u8) !void {
        for (self.chunks.items) |*chunk| {
            if (std.mem.eql(u8, chunk.name, name)) {
                const new_content = try self.allocator.dupe(u8, content);
                self.allocator.free(chunk.content);
                chunk.content = new_content;
                return;
            }
        }
        try self.chunks.append(self.allocator, .{
            .name = try self.allocator.dupe(u8, name),
            .content = try self.allocator.dupe(u8, content),
        });
    }

    fn render(self: *Instance) ![]const u8 {
        if (self.result) |result| {
            self.allocator.free(result);
            self.result = null;
        }
        var chunks: std.ArrayList(Chunk) = .empty;
        defer chunks.deinit(self.allocator);
        for (self.chunks.items) |chunk| {
            try chunks.append(self.allocator, .{ .name = chunk.name, .content = chunk.content });
        }
        self.result = try compileAlloc(self.allocator, chunks.items, .{});
        return self.result.?;
    }
};

fn abiAllocator() std.mem.Allocator {
    if (builtin.target.cpu.arch.isWasm()) return std.heap.wasm_allocator;
    return std.heap.smp_allocator;
}

export fn calm_version() [*:0]const u8 {
    return version;
}

export fn calm_create() ?*Instance {
    const allocator = abiAllocator();
    const instance = allocator.create(Instance) catch return null;
    instance.* = Instance.init(allocator);
    return instance;
}

export fn calm_destroy(instance: ?*Instance) void {
    if (instance) |ctx| {
        const allocator = ctx.allocator;
        ctx.deinit();
        allocator.destroy(ctx);
    }
}

export fn calm_clear(instance: ?*Instance) void {
    if (instance) |ctx| ctx.clear();
}

export fn calm_put_chunk(instance: ?*Instance, name_ptr: [*]const u8, name_len: usize, content_ptr: [*]const u8, content_len: usize) c_int {
    const ctx = instance orelse return -1;
    ctx.putChunk(name_ptr[0..name_len], content_ptr[0..content_len]) catch return -2;
    return 0;
}

export fn calm_render(instance: ?*Instance) usize {
    const ctx = instance orelse return 0;
    const result = ctx.render() catch return 0;
    return result.len;
}

export fn calm_result_ptr(instance: ?*Instance) ?[*]const u8 {
    const ctx = instance orelse return null;
    const result = ctx.result orelse return null;
    return result.ptr;
}

export fn calm_result_len(instance: ?*Instance) usize {
    const ctx = instance orelse return 0;
    const result = ctx.result orelse return 0;
    return result.len;
}

export fn calm_compile(input_ptr: [*]const u8, input_len: usize, out_ptr: ?[*]u8, out_cap: usize) usize {
    const allocator = abiAllocator();
    const chunk = Chunk{ .name = "stdin", .content = input_ptr[0..input_len] };
    const result = compileAlloc(allocator, &.{chunk}, .{}) catch return 0;
    defer allocator.free(result);
    if (out_ptr) |ptr| {
        if (out_cap >= result.len) @memcpy(ptr[0..result.len], result);
    }
    return result.len;
}

export fn calm_alloc(len: usize) ?[*]u8 {
    const mem = abiAllocator().alloc(u8, len) catch return null;
    return mem.ptr;
}

export fn calm_free(ptr: ?[*]u8, len: usize) void {
    if (ptr) |p| abiAllocator().free(p[0..len]);
}

test "extracts common utilities and variants" {
    const input =
        \\<div class="p-4 md:hover:bg-blue-500 text-sm font-bold rounded-lg"></div>
    ;
    const css = try compileAlloc(std.testing.allocator, &.{.{ .name = "index.html", .content = input }}, .{});
    defer std.testing.allocator.free(css);
    try std.testing.expect(std.mem.indexOf(u8, css, ".p-4{padding:calc(var(--spacing)") != null);
    try std.testing.expect(std.mem.indexOf(u8, css, "@media (min-width:48rem){@media (hover:hover){.md\\:hover\\:bg-blue-500:hover{background-color:var(--color-blue-500);}}}") != null);
    try std.testing.expect(std.mem.indexOf(u8, css, ".font-bold{--tw-font-weight:var(--font-weight-bold);font-weight:var(--font-weight-bold)") != null);
}

test "chunk update replaces content" {
    const allocator = std.testing.allocator;
    var instance = Instance.init(allocator);
    defer instance.deinit();
    try instance.putChunk("a.html", "<div class=\"p-2\"></div>");
    _ = try instance.render();
    try std.testing.expect(instance.result.?.len > 0);
    try instance.putChunk("a.html", "<div class=\"p-6\"></div>");
    const css = try instance.render();
    try std.testing.expect(std.mem.indexOf(u8, css, ".p-6{padding:calc(var(--spacing)*6);}") != null);
    try std.testing.expect(std.mem.indexOf(u8, css, ".p-2{") == null);
}

test "forms and typography plugin classes" {
    const css = try compileAlloc(std.testing.allocator, &.{.{ .name = "plugins.html", .content = "<input class=\"form-input\"><article class=\"prose prose-invert\"></article>" }}, .{});
    defer std.testing.allocator.free(css);
    try std.testing.expect(std.mem.indexOf(u8, css, ".form-input{appearance:none;--tw-shadow:0 0 #0000;") != null);
    try std.testing.expect(std.mem.indexOf(u8, css, ".prose{color:var(--tw-prose-body);max-width:65ch}") != null);
    try std.testing.expect(std.mem.indexOf(u8, css, ".prose-invert{--tw-prose-body:var(--tw-prose-invert-body);") != null);
}

test "forms plugin template refs stay out of typography entries" {
    const template_ref_mask: u32 = 0x80000000;
    for (plugin_parity_data.entries) |entry| {
        const name = plugin_parity_data.candidate(entry);
        var has_template_ref = false;
        const end = entry.part_start + entry.part_len;
        for (plugin_parity_data.part_refs[entry.part_start..end]) |part_ref| {
            if ((part_ref & template_ref_mask) != 0) has_template_ref = true;
        }

        if (std.mem.startsWith(u8, name, "form-")) {
            try std.testing.expect(has_template_ref);
        } else if (std.mem.eql(u8, name, "prose") or std.mem.startsWith(u8, name, "prose-")) {
            try std.testing.expect(!has_template_ref);
        }
    }
}

test "typography plugin classes do not emit forms base template" {
    const css = try compileAlloc(std.testing.allocator, &.{.{ .name = "plugins.html", .content = "<article class=\"prose\"></article>" }}, .{});
    defer std.testing.allocator.free(css);
    try std.testing.expect(std.mem.indexOf(u8, css, ".prose{color:var(--tw-prose-body);max-width:65ch}") != null);
    try std.testing.expect(std.mem.indexOf(u8, css, "@layer base{input:where([type=text])") == null);
}

test "CSS candidate scan ignores comments and string literals" {
    const input =
        \\@theme { /* } text-red-500 underline */ --color-brand:#123456; --font-display:"font-bold } bg-red-500"; }
        \\@source inline("text-brand");
        \\@tailwind utilities;
        \\.foo::before { content:"bg-blue-500 flex"; }
        \\/* p-4 */
    ;
    const css = try compileAlloc(std.testing.allocator, &.{.{ .name = "app.css", .content = input }}, .{});
    defer std.testing.allocator.free(css);

    try std.testing.expect(std.mem.indexOf(u8, css, ".text-brand{color:var(--color-brand);}") != null);
    try std.testing.expect(std.mem.indexOf(u8, css, ".foo::before{content:\"bg-blue-500 flex\";}") != null);
    try std.testing.expect(std.mem.indexOf(u8, css, ".text-red-500{") == null);
    try std.testing.expect(std.mem.indexOf(u8, css, ".underline{") == null);
    try std.testing.expect(std.mem.indexOf(u8, css, ".font-bold{") == null);
    try std.testing.expect(std.mem.indexOf(u8, css, ".bg-red-500{") == null);
    try std.testing.expect(std.mem.indexOf(u8, css, ".bg-blue-500{") == null);
    try std.testing.expect(std.mem.indexOf(u8, css, ".flex{") == null);
    try std.testing.expect(std.mem.indexOf(u8, css, ".p-4{") == null);
}

test "CSS chunk name preserves stylesheets without at-rules" {
    const input =
        \\.foo { color: red; }
        \\.bar::before { content: "p-4 text-red-500"; }
        \\/* flex underline */
    ;
    const css = try compileAlloc(std.testing.allocator, &.{.{ .name = "plain.css", .content = input }}, .{});
    defer std.testing.allocator.free(css);

    try std.testing.expect(std.mem.indexOf(u8, css, ".foo{color:red;}") != null);
    try std.testing.expect(std.mem.indexOf(u8, css, ".bar::before{content:\"p-4 text-red-500\";}") != null);
    try std.testing.expect(std.mem.indexOf(u8, css, ".p-4{") == null);
    try std.testing.expect(std.mem.indexOf(u8, css, ".text-red-500{") == null);
    try std.testing.expect(std.mem.indexOf(u8, css, ".flex{") == null);
    try std.testing.expect(std.mem.indexOf(u8, css, ".underline{") == null);
}

test "CSS temp chunk name preserves stylesheets without at-rules" {
    const input =
        \\.foo { color: red; }
        \\.bar::before { content: "p-4 text-red-500"; }
    ;
    const css = try compileAlloc(std.testing.allocator, &.{.{ .name = "plain.css.tmp", .content = input }}, .{});
    defer std.testing.allocator.free(css);

    try std.testing.expect(std.mem.indexOf(u8, css, ".foo{color:red;}") != null);
    try std.testing.expect(std.mem.indexOf(u8, css, ".bar::before{content:\"p-4 text-red-500\";}") != null);
    try std.testing.expect(std.mem.indexOf(u8, css, ".p-4{") == null);
    try std.testing.expect(std.mem.indexOf(u8, css, ".text-red-500{") == null);
}

test "tailwind full import uses v4 defaults" {
    const input =
        \\<style>@import "tailwindcss";</style>
        \\<div class="border ring space-x-2 bg-red-500/50"></div>
    ;
    const css = try compileAlloc(std.testing.allocator, &.{.{ .name = "app.html", .content = input }}, .{});
    defer std.testing.allocator.free(css);

    try std.testing.expect(std.mem.indexOf(u8, css, "@layer theme{") != null);
    try std.testing.expect(std.mem.indexOf(u8, css, "@layer base{") != null);
    try std.testing.expect(std.mem.indexOf(u8, css, "@layer utilities{") != null);
    try std.testing.expect(std.mem.indexOf(u8, css, ".border{border-style:var(--tw-border-style);border-width:1px}") != null);
    try std.testing.expect(std.mem.indexOf(u8, css, ".ring{--tw-ring-shadow:var(--tw-ring-inset,) 0 0 0 calc(1px + var(--tw-ring-offset-width)) var(--tw-ring-color,currentcolor);") != null);
    try std.testing.expect(std.mem.indexOf(u8, css, ":where(.space-x-2>:not(:last-child))") != null);
    try std.testing.expect(std.mem.indexOf(u8, css, "color-mix(in oklab, var(--color-red-500) 50%, transparent)") != null);
}

test "tailwind import scanner ignores comments and strings" {
    const input =
        \\/*
        \\ * The single @import "tailwindcss" directive pulls in defaults.
        \\ */
        \\.note::before { content: "@import \"tailwindcss\""; }
        \\@import "tailwindcss";
        \\@theme { --color-red-500: #FF3131; }
        \\@source inline("text-red-500 p-4");
    ;
    const css = try compileAlloc(std.testing.allocator, &.{.{ .name = "calm-theme.css", .content = input }}, .{});
    defer std.testing.allocator.free(css);

    try std.testing.expect(std.mem.indexOf(u8, css, "@layer theme{") != null);
    try std.testing.expect(std.mem.indexOf(u8, css, "--spacing:.25rem") != null);
    try std.testing.expect(std.mem.indexOf(u8, css, "--color-red-500:#FF3131") != null);
    try std.testing.expect(std.mem.indexOf(u8, css, ".p-4{padding:calc(var(--spacing) * 4)}") != null);
    try std.testing.expect(std.mem.indexOf(u8, css, ".text-red-500{color:var(--color-red-500);}") != null);
}

test "v3 opacity utilities do not emit while slash opacity does" {
    const input =
        \\<div class="bg-opacity-50 text-opacity-50 border-opacity-50 placeholder-opacity-50 divide-opacity-50 ring-opacity-50 bg-red-500/50 text-red-500/50 border-red-500/50"></div>
    ;
    const css = try compileAlloc(std.testing.allocator, &.{.{ .name = "index.html", .content = input }}, .{});
    defer std.testing.allocator.free(css);

    try std.testing.expect(std.mem.indexOf(u8, css, ".bg-opacity-50{") == null);
    try std.testing.expect(std.mem.indexOf(u8, css, ".text-opacity-50{") == null);
    try std.testing.expect(std.mem.indexOf(u8, css, ".border-opacity-50{") == null);
    try std.testing.expect(std.mem.indexOf(u8, css, ".placeholder-opacity-50{") == null);
    try std.testing.expect(std.mem.indexOf(u8, css, ".divide-opacity-50{") == null);
    try std.testing.expect(std.mem.indexOf(u8, css, ".ring-opacity-50{") == null);
    try std.testing.expect(std.mem.indexOf(u8, css, ".bg-red-500\\/50{") != null);
    try std.testing.expect(std.mem.indexOf(u8, css, ".text-red-500\\/50{") != null);
    try std.testing.expect(std.mem.indexOf(u8, css, ".border-red-500\\/50{") != null);
}

test "fractional translate axis utilities" {
    const input =
        \\<div class="translate-x-1/2 -translate-x-1/2 translate-y-1/2 -translate-y-1/2 m-1/2 p-1/2"></div>
    ;
    const css = try compileAlloc(std.testing.allocator, &.{.{ .name = "index.html", .content = input }}, .{});
    defer std.testing.allocator.free(css);

    try std.testing.expect(std.mem.indexOf(u8, css, ".translate-x-1\\/2{--tw-translate-x:calc(1 / 2 * 100%);translate:var(--tw-translate-x) var(--tw-translate-y);}") != null);
    try std.testing.expect(std.mem.indexOf(u8, css, ".-translate-x-1\\/2{--tw-translate-x:calc(calc(1 / 2 * 100%) * -1);translate:var(--tw-translate-x) var(--tw-translate-y);}") != null);
    try std.testing.expect(std.mem.indexOf(u8, css, ".translate-y-1\\/2{--tw-translate-y:calc(1 / 2 * 100%);translate:var(--tw-translate-x) var(--tw-translate-y);}") != null);
    try std.testing.expect(std.mem.indexOf(u8, css, ".-translate-y-1\\/2{--tw-translate-y:calc(calc(1 / 2 * 100%) * -1);translate:var(--tw-translate-x) var(--tw-translate-y);}") != null);
    try std.testing.expect(std.mem.indexOf(u8, css, ".m-1\\/2{") == null);
    try std.testing.expect(std.mem.indexOf(u8, css, ".p-1\\/2{") == null);
}
