# lib/json_esc.awk — funzione json_esc() canonica per tutti i tool awk
#
# Include con: @include "lib/json_esc.awk"  (richiede gawk 4+)
#
# Uso:
#   escaped = json_esc(stringa)
#
# Gestisce:
#   - Caratteri speciali JSON: \\ " \t \r \b \f
#   - Caratteri di controllo ASCII < 0x20 → \uXXXX
#   - Byte non-ASCII >= 0x80 (Latin-1, ISO-8859-1) → "?"
#     Necessario perché i log Oracle possono contenere messaggi localizzati
#     in italiano/francese con encoding Latin-1 (es. 0xe8 per "è").
#
# REQUISITO: il programma awk deve essere invocato con LC_ALL=C
# per garantire che ogni byte sia trattato come carattere singolo.
# Senza LC_ALL=C, gawk in locale UTF-8 potrebbe aggregare i byte multibyte
# in un singolo carattere e il lookup non funzionerebbe correttamente.
#
# Stringhe di lookup precostituite (evitano sprintf/ord per performance):
#   _CTRL: caratteri di controllo \x01-\x1F (index restituisce la posizione 1-based)
#   _HIGH: byte \x80-\xFF (index restituisce > 0 se il byte è non-ASCII)

BEGIN {
    _CTRL = "\001\002\003\004\005\006\007\010\011\012\013\014\015\016\017\020\021\022\023\024\025\026\027\030\031\032\033\034\035\036\037"
    _HIGH = "\200\201\202\203\204\205\206\207\210\211\212\213\214\215\216\217\220\221\222\223\224\225\226\227\230\231\232\233\234\235\236\237\240\241\242\243\244\245\246\247\250\251\252\253\254\255\256\257\260\261\262\263\264\265\266\267\270\271\272\273\274\275\276\277\300\301\302\303\304\305\306\307\310\311\312\313\314\315\316\317\320\321\322\323\324\325\326\327\330\331\332\333\334\335\336\337\340\341\342\343\344\345\346\347\350\351\352\353\354\355\356\357\360\361\362\363\364\365\366\367\370\371\372\373\374\375\376\377"
}

function json_esc(s,    out, i, c, v) {
    out = ""
    for (i = 1; i <= length(s); i++) {
        c = substr(s, i, 1)
        if      (c == "\\") { out = out "\\\\"; continue }
        if      (c == "\"") { out = out "\\\""; continue }
        if      (c == "\t") { out = out "\\t";  continue }
        if      (c == "\r") { out = out "\\r";  continue }
        if      (c == "\b") { out = out "\\b";  continue }
        if      (c == "\f") { out = out "\\f";  continue }
        # Caratteri di controllo ASCII < 0x20
        v = index(_CTRL, c)
        if (v > 0) { out = out sprintf("\\u%04x", v); continue }
        # Byte non-ASCII >= 0x80 (Latin-1): sostituisce con "?"
        v = index(_HIGH, c)
        if (v > 0) { out = out "?"; continue }
        out = out c
    }
    return out
}
