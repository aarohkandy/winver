# winver jobs

This folder is the public job recipe book.

Keep scripts, small config, and safe docs here. Keep datasets, checkpoints, model weights, generated outputs, caches, and secrets on the Surface under `%USERPROFILE%\.winver`.

Every job receives:

- `WINVER_REPO`
- `WINVER_DATA`
- `WINVER_RUNS`
- `WINVER_LOGS`
- `WINVER_JOB_NAME`

From the Mac, monitor and pull results with:

```sh
./bin/winver job monitor latest
./bin/winver job pull logs latest
./bin/winver job pull runs JOB_OUTPUT_FOLDER
```
