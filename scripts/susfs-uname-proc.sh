#!/bin/bash
# SUSFS: extend uname spoofing to /proc/version and
# /proc/sys/kernel/{osrelease,version} so system UI and apps that read
# procfs instead of the uname() syscall also see the spoofed values.
#
# The stock SUSFS patch only hooks the uname() syscall (kernel/sys.c), so
# Settings -> About -> kernel version (/proc/version) and tools reading
# /proc/sys/kernel/osrelease still show the real build string. This patch
# routes those two procfs readers through the same susfs_spoof_uname()
# buffer, keeping the spoof consistent across all three interfaces.
#
# Idempotent: safe to run multiple times.
set -euo pipefail
KDIR="${1:-${KDIR_OVERRIDE:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}}"
cd "$KDIR"

echo "=== [SUSFS] patch /proc/version + osrelease spoofing ==="
python3 - <<'PYEOF'
def patch_file(path, old, new, label):
    s = open(path).read()
    assert s.count(old) == 1, f'anchor not unique in {path}: {label}'
    open(path, 'w').write(s.replace(old, new, 1))
    print(f'patched {path} ({label})')

# ---- 1. fs/proc/version.c ----
vp = open('fs/proc/version.c').read()
if 'susfs_is_uname_spoof_buffer_set' not in vp:
    old = '''static int version_proc_show(struct seq_file *m, void *v)
{
	seq_printf(m, linux_proc_banner,
		utsname()->sysname,
		utsname()->release,
		utsname()->version);
	return 0;
}'''
    new = '''#ifdef CONFIG_KSU_SUSFS
#include <linux/jump_label.h>
#include <linux/string.h>
extern struct static_key_false susfs_is_uname_spoof_buffer_set;
extern void susfs_spoof_uname(struct new_utsname* tmp);
#endif

static int version_proc_show(struct seq_file *m, void *v)
{
	struct new_utsname tmp;
	memcpy(&tmp, utsname(), sizeof(tmp));
#ifdef CONFIG_KSU_SUSFS
	if (static_branch_likely(&susfs_is_uname_spoof_buffer_set))
		susfs_spoof_uname(&tmp);
#endif
	seq_printf(m, linux_proc_banner, tmp.sysname, tmp.release, tmp.version);
	return 0;
}'''
    patch_file('fs/proc/version.c', old, new, 'version_proc_show')
else:
    print('fs/proc/version.c already patched')

# ---- 2. kernel/utsname_sysctl.c ----
us = open('kernel/utsname_sysctl.c').read()
if 'proc_do_uts_string_spoof' not in us:
    anchor = '''	return r;
}
#else
#define proc_do_uts_string NULL
#endif'''
    add = '''	return r;
}

#if defined(CONFIG_KSU_SUSFS) && defined(CONFIG_PROC_SYSCTL)
#include <linux/jump_label.h>
#include <linux/string.h>
extern struct static_key_false susfs_is_uname_spoof_buffer_set;
extern void susfs_spoof_uname(struct new_utsname* tmp);

/*
 * SUSFS: same as proc_do_uts_string for reads, but returns the spoofed
 * release/version for the osrelease/version entries when uname spoofing
 * is enabled. Writes fall through to the original handler.
 */
static int proc_do_uts_string_spoof(struct ctl_table *table, int write,
		  void __user *buffer, size_t *lenp, loff_t *ppos)
{
	struct ctl_table uts_table;
	struct new_utsname tmp;

	if (write)
		return proc_do_uts_string(table, write, buffer, lenp, ppos);

	memcpy(&tmp, utsname(), sizeof(tmp));
	if (static_branch_likely(&susfs_is_uname_spoof_buffer_set))
		susfs_spoof_uname(&tmp);

	memcpy(&uts_table, table, sizeof(uts_table));
	if (!strcmp(table->procname, "osrelease"))
		uts_table.data = tmp.release;
	else if (!strcmp(table->procname, "version"))
		uts_table.data = tmp.version;
	else
		return proc_do_uts_string(table, write, buffer, lenp, ppos);

	return proc_dostring(&uts_table, write, buffer, lenp, ppos);
}
#endif
#else
#define proc_do_uts_string NULL
#endif'''
    assert us.count(anchor) == 1, 'utsname_sysctl.c anchor not found'
    us = us.replace(anchor, add, 1)

    for name, field in (('osrelease', 'release'), ('version', 'version')):
        old_entry = (f'''		.procname	= "{name}",
		.data		= init_uts_ns.name.{field},
		.maxlen		= sizeof(init_uts_ns.name.{field}),
		.mode		= 0444,
		.proc_handler	= proc_do_uts_string,''')
        new_entry = (f'''		.procname	= "{name}",
		.data		= init_uts_ns.name.{field},
		.maxlen		= sizeof(init_uts_ns.name.{field}),
		.mode		= 0444,
#if defined(CONFIG_KSU_SUSFS) && defined(CONFIG_PROC_SYSCTL)
		.proc_handler	= proc_do_uts_string_spoof,
#else
		.proc_handler	= proc_do_uts_string,
#endif''')
        assert us.count(old_entry) == 1, f'{name} entry not found'
        us = us.replace(old_entry, new_entry, 1)

    open('kernel/utsname_sysctl.c', 'w').write(us)
    print('patched kernel/utsname_sysctl.c (osrelease + version)')
else:
    print('kernel/utsname_sysctl.c already patched')

# ---- 3. init/version.c: hide the build environment in /proc/version ----
# linux_proc_banner bakes LINUX_COMPILE_BY/HOST/COMPILER in at build time, so
# /proc/version leaks the CI host (runner@runnervm7aw5e) and toolchain even
# when uname() is spoofed. Replace the compile-info part with a neutral
# vendor-style string so the procfs view no longer reveals the build box.
iv = open('init/version.c').read()
if 'builder@build-server' not in iv:
    old_banner = '''const char linux_proc_banner[] =
	"%s version %s"
	" (" LINUX_COMPILE_BY "@" LINUX_COMPILE_HOST ")"
	" (" LINUX_COMPILER ") %s\\n";'''
    new_banner = '''const char linux_proc_banner[] =
	"%s version %s"
	" (builder@build-server)"
	" (Android clang version 14.0.6)"
	" %s\\n";'''
    assert iv.count(old_banner) == 1, 'linux_proc_banner anchor not found'
    open('init/version.c', 'w').write(iv.replace(old_banner, new_banner, 1))
    print('patched init/version.c (linux_proc_banner build info)')
else:
    print('init/version.c already patched')
PYEOF
echo "=== [SUSFS] uname-proc patch done ==="
