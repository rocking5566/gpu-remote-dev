# AGENTS.md

## Remote GPU dev

Read, edit and run git here; build, test and profile on the remote server.

Read `.remote.env` for the target — never hardcode its values from memory,
they all move. A fresh clone has no `.remote.env`: copy `.remote.env.example`
over and ask which host to use. Its placeholder is deliberately unresolvable,
so never sync to it.

Sync, then run. Skipping the sync silently builds stale code:

    rsync -az --delete $RSYNC_EXCLUDES ./ "$REMOTE_HOST:$REMOTE_PATH/"
    ssh "$REMOTE_HOST" "docker exec $REMOTE_CONTAINER \
        bash -lc 'cd $CONTAINER_PATH && <cmd>'"

`--delete` makes the remote an exact mirror, so anything generated there and
not covered by `RSYNC_EXCLUDES` is destroyed on the next sync — copy results
back before syncing again.

Never commit from the remote; its `.git` is excluded and therefore stale.
