# Emit "<phase> <guarded|UNGUARDED>" for every `include_tasks: <phase>.yml` in
# main.yml.
#
# A phase's block runs from its `- name:` to the NEXT `- name:`, and the guard
# must appear inside that block. A `grep -A N` window cannot express this: it
# reads past the block end and picks up the FOLLOWING phase's guard, which is
# how the first version of this check reported a phase as guarded seconds after
# its guard had been deleted.
/^- name:/ {
  if (phase != "") print phase, (guarded ? "guarded" : "UNGUARDED")
  phase = ""; guarded = 0
}
/include_tasks: [a-z-]+\.yml/ {
  match($0, /include_tasks: [a-z-]+\.yml/)
  p = substr($0, RSTART + 15, RLENGTH - 15)
  sub(/\.yml$/, "", p)
  phase = p
}
/not ansible_check_mode/ { if (phase != "") guarded = 1 }
END { if (phase != "") print phase, (guarded ? "guarded" : "UNGUARDED") }
