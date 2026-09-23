"""Small Swift lexical mask for policy checks, not a Swift parser.

Offsets and newlines are preserved. Literal text and comments are blanked;
executable interpolation is retained, including nested strings/comments.
"""

from dataclasses import dataclass


@dataclass
class MaskedSwift:
    code: str
    comments: list[tuple[int, int]]
    errors: list[tuple[int, str]]


def mask_swift(source: str) -> MaskedSwift:
    out = list(source)
    comments = []
    errors = []
    length = len(source)

    def blank(start, end):
        for index in range(start, end):
            if source[index] not in "\r\n":
                out[index] = " "

    def string(start, hashes):
        quote = start + hashes
        width = 3 if source.startswith('"""', quote) else 1
        closing = '"' * width + '#' * hashes
        escape = '\\' + '#' * hashes
        index = quote + width
        blank(start, index)
        while index < length:
            if source.startswith(closing, index):
                blank(index, index + len(closing))
                return index + len(closing)
            if source.startswith(escape, index):
                after = index + len(escape)
                if after < length and source[after] == '(':
                    blank(index, after)
                    index = code(after + 1, interpolation=True)
                    continue
                # Escaped quote/backslash cannot terminate the string.
                blank(index, min(after + 1, length))
                index = after + 1
                continue
            blank(index, index + 1)
            index += 1
        errors.append((start, "unterminated string literal"))
        return length

    def code(index, interpolation=False):
        parentheses = 1 if interpolation else 0
        while index < length:
            start = index
            if source.startswith('//', index):
                end = source.find('\n', index)
                index = length if end == -1 else end
                comments.append((start, index))
                blank(start, index)
            elif source.startswith('/*', index):
                depth = 1
                index += 2
                while index < length and depth:
                    if source.startswith('/*', index):
                        depth += 1
                        index += 2
                    elif source.startswith('*/', index):
                        depth -= 1
                        index += 2
                    else:
                        index += 1
                comments.append((start, index))
                blank(start, index)
                if depth:
                    errors.append((start, "unterminated block comment"))
            else:
                quote = index
                while quote < length and source[quote] == '#':
                    quote += 1
                if quote < length and source[quote] == '"':
                    index = string(index, quote - index)
                    continue
                if interpolation:
                    if source[index] == '(':
                        parentheses += 1
                    elif source[index] == ')':
                        parentheses -= 1
                        if parentheses == 0:
                            return index + 1
                index += 1
        if interpolation:
            errors.append((length, "unterminated string interpolation"))
        return index

    code(0)
    return MaskedSwift(''.join(out), comments, errors)
