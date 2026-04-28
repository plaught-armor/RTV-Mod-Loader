# RTV Mod Loader — DEPRECATED (2026-04-26)

This loader is **no longer maintained**. Use [**vostok-mod-loader**](https://github.com/ametrocavich/vostok-mod-loader) instead.

## Why deprecated

vostok-mod-loader (community fork, MIT) solves the problems this loader was working around:

- **Hook API** (`hook(name, cb)`, `add_hook(path, method, cb)`) — no more whole-script `take_over_path`. Mods intercept individual vanilla methods pre/post/replace/callback.
- **Source rewriting** via GDSC detokenization — rewritten vanilla scripts ship at original paths, no class_name corruption (Godot bug #83542).
- **Two-pass boot** + static-init mount — solves autoload-pinning before mod scripts can run.
- **Crash recovery + safe mode** — heartbeat, restart counter, sentinel files.
- **Wider compat surface** — godot-mod-loader and tetrahydroc RTVModLib API mirrors.
- **Modular source** + wiki — 20-file split + per-subsystem rationale.

This loader = ~2000-line monolith with `take_over_path` only and ModWorkshop browse-tab. Not enough to compete.

## Migration

If you're a mod author shipping against this loader: declare hook callbacks via `Engine.get_meta("RTVModLib")` after `await lib.frameworks_ready`. See the loader's [Hooks wiki page](https://github.com/ametrocavich/vostok-mod-loader/wiki/Hooks).

If you're an end user: delete `modloader.gd` + `override.cfg` from your game dir, install vostok-mod-loader from its [Releases](https://github.com/ametrocavich/vostok-mod-loader/releases), then drop your mods back into `mods/`.

## RTV-Coop status

The Road to Vostok co-op mod migrated to vostok-mod-loader on 2026-04-26. Install instructions: [RTV-Coop INSTALLATION.md](https://github.com/plaught-armor/RTV-Coop/blob/main/INSTALLATION.md).

## License

MIT — see [LICENSE](LICENSE). Source archived at last release tag for historical reference.
