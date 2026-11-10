# user-config

Your own files for this checkout of sbx-capsule: agent profiles, local kits
and kit args files. `user-config/` is gitignored, like `.env`. This folder,
`user-config.example/`, is the tracked template: `make init` copies it to
`user-config/` if you don't have one yet (or run
`cp -R user-config.example user-config`).

No sandbox VM mounts `user-config/`, so no agent can change what the next VM
is created with. Keep it that way: the tool refuses profiles, kits and args
files that are inside a sandbox folder.

```
user-config/
  agents/<name>.env           agent profiles: make new AGENT=<name>, make run N=<n> AGENT=<name>
  kits/<kit>/<kit>.yaml       local sbx kits (mixins) that profiles add with --kit
  <kit>.args                  kit args files (--kit-args-file): <kit>.<arg>=<value> lines
```

The examples set up Pi on models served by your own machine:

1. `agents/pi.env.example`: rename it to `agents/pi.env`.
2. `pi-local-models.args.example`: rename it to `pi-local-models.args`, and
   put in your model ids (`curl -s http://127.0.0.1:8080/v1/models` on the
   host lists them). No quotes around `default_model`.
3. `kits/pi-local-models/`: change the port there if your server isn't on
   8080.
4. `make doctor` checks the profile. Then `make new AGENT=pi` and
   `make run N=<n>`.

Never put API keys in these files: name them in a profile's `CREDENTIALS`
and set them with `sbx secret set` (README.md, "Kit-based agents and
profiles").
