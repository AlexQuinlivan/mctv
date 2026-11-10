package mctv.aot.bake;

import java.util.Collection;
import java.util.Map;
import java.util.TreeMap;

/** Just enough JSON for bake.json. Keys are sorted, so the output is stable. */
final class Json {
    static String write(Object value) {
        StringBuilder b = new StringBuilder();
        write(b, value, "");
        return b.toString();
    }

    private static void write(StringBuilder b, Object v, String indent) {
        if (v == null) {
            b.append("null");
        } else if (v instanceof Map<?, ?> map) {
            if (map.isEmpty()) { b.append("{}"); return; }
            b.append("{\n");
            int i = 0;
            for (Map.Entry<?, ?> e : new TreeMap<>(map).entrySet()) {
                b.append(indent).append("  ");
                string(b, e.getKey().toString());
                b.append(": ");
                write(b, e.getValue(), indent + "  ");
                b.append(++i < map.size() ? ",\n" : "\n");
            }
            b.append(indent).append('}');
        } else if (v instanceof Collection<?> list) {
            if (list.isEmpty()) { b.append("[]"); return; }
            b.append("[\n");
            int i = 0;
            for (Object o : list) {
                b.append(indent).append("  ");
                write(b, o, indent + "  ");
                b.append(++i < list.size() ? ",\n" : "\n");
            }
            b.append(indent).append(']');
        } else if (v instanceof Number || v instanceof Boolean) {
            b.append(v);
        } else {
            string(b, v.toString());
        }
    }

    private static void string(StringBuilder b, String s) {
        b.append('"');
        for (char c : s.toCharArray()) {
            switch (c) {
                case '"' -> b.append("\\\"");
                case '\\' -> b.append("\\\\");
                case '\n' -> b.append("\\n");
                case '\t' -> b.append("\\t");
                default -> {
                    if (c < 0x20) b.append(String.format("\\u%04x", (int) c));
                    else b.append(c);
                }
            }
        }
        b.append('"');
    }
}
