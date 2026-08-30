# Seal tooling

These run on the BUILD VM only. `doseal.cmd` deletes them at seal time, so none of
them reach a customer VM.

They used to live only on ycnode01, in three copies - `/root/goldenscript/v262`,
`/root/kit-v262`, `/root/goldenscript/v262vcenter` - which drifted apart and produced
most of the defects found in the 2026-08-30 audit: one kit's `Unattend-Seal.xml` had
no `SkipRearm` element at all, and the three kits disagreed on seven files.

GitHub is the source of truth now. `yc-build-tree.sh` fetches this directory and falls
back to the local kit only if GitHub is unreachable, and says which it used.

`Unattend-Seal.xml` is deliberately NOT here: it ships in the payload zip, and the
payload copy is the canonical one. A second copy in this directory would be a third
version of the file that started the whole problem.
