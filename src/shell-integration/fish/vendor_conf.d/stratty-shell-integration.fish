# Stratty lifecycle metadata layered on Ghostty's bundled Fish integration.
# This file is intentionally separate so upstream Ghostty integration remains
# almost entirely unchanged.

if status --is-interactive
    set --global __stratty_lifecycle_generation 0

    function __stratty_next_lifecycle_generation
        set --global __stratty_lifecycle_generation (math $__stratty_lifecycle_generation + 1)
        printf %s $__stratty_lifecycle_generation
    end

    function __stratty_encoded_command_tokens --argument-names command_text
        set --local parsed
        printf %s "$command_text" | read --tokenize --list parsed

        set --local encoded
        for token in $parsed
            set --append encoded (string escape --style=url -- "$token")
        end
        string join , -- $encoded
    end

    function __stratty_mark_output_start --argument-names command_text
        set --local generation (__stratty_next_lifecycle_generation)
        set --local tokens (__stratty_encoded_command_tokens "$command_text")
        printf '\e]133;C;stratty_owner=%s;stratty_generation=%s;stratty_tokens=%s\a' \
            $fish_pid $generation "$tokens"
    end

    function __stratty_mark_output_end --argument-names exit_code
        set --local generation (__stratty_next_lifecycle_generation)
        printf '\e]133;D;%s;stratty_owner=%s;stratty_generation=%s\a' \
            "$exit_code" $fish_pid $generation
    end
end
