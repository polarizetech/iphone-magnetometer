# .agents — managed by KIT Adaptive Preregistration

Everything in this folder was installed by [KIT Adaptive Preregistration](https://github.com/polarizetech/adaptive-preregistration) from the kit recorded in `kit_ap.lock`.
Don't edit these files here. Updates overwrite them, and `update` refuses to run while they differ from what was installed.
Change the kit instead, then pull the change in:

```bash
.agents/bin/kit_ap update           # pull the latest kit and re-apply
.agents/bin/kit_ap status           # installed version, modules, whether it's current
.agents/bin/kit_ap add <module>     # or: remove <module>
```
