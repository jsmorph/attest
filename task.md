Use Nix to build an attestable AMI that runs `app.sh`, an example
application that justs gets a Nitro attestation and prints it as JSON.

See
[`aws/nitrotpm-attestation-samples`](https://github.com/aws/nitrotpm-attestation-samples)
for background.

You do all of your work on a x64 EC2 instance running Amazon
Linux 2023.  You interact with this instance `dev` with `ssh` and `scp`:

```Shell
ssh dev ls /
```

You assume that `dev` has the required permissions.  If not, report
what it needs, and then I will do what's required.

That's how you develop: You use `dev` basically as a shell to build
the AMI (using Nix).

See `notes.sh` for an earlier attempt at the process.

You'll create two scripts: `build.sh` and `run.sh`.

You write `build.sh` incrementally as you make progress doing one-off
commands (`ssh` or `scp`).  As you make progress, update/edit
`build.sh` to have a clean script that can run from a clean EC2
instance.  `build.sh` should take an optional argument, which defaults
to `app.sh`, that gets embedded in the AMI and is automatically run by
the instance.

The script `run.sh` should demonstrate running the attestable app AMI
and getting the attestation from the EC2 console logging output.

## Work style

No gratuitous or obvious comments.  Keep things as simple as possible.
Simplicity is the greatest virtue.  Minimize third-party dependencies.
Do not be lazy.  When you encounter a problem, work on it directly.
Do no rush to some hack or work-around.  Instead of guessing, look up
authoritative documentation.

Keep all interesting development notes, including links to
authoritative documentation, in a file called `devnotes.md`, which you
update as you go.  Use complete sentences.  You are writing for an
expert with no tolerance for bullshit, guessing, or any other that the
highest quality technical work.

## Tasks

- [ ] Research how to build attestable AMIs using Nix.
- [ ] Make any edits you want to the example `app.sh`.
- [ ] Start interactive development using `dev`.
- [ ] Create and update `build.sh` as you make progress.
- [ ] Create and update `run.sh` as you make progress.
- [ ] Remove obsolete AMIs, volumes, or other artifacts you create as you go.
- [ ] Keep `devnotes.md` current with important observations.
