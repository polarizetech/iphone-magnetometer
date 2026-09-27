# ARCHIVING.md — When and how to register or deposit: OSF and Zenodo

**Applies to:** anyone deciding whether a preregistration, result or release from this repo goes to an
external archive, and doing it.
**Installed by:** the KIT Adaptive Preregistration `prereg` module. `PREREG_PROTOCOL.md` §2 and §11 point here.
**License:** CC BY 4.0, from [KIT Adaptive Preregistration](https://github.com/polarizetech/adaptive-preregistration). Reuse it with credit.

---

## 0. What an archive adds, and what it doesn't

- **A hash and a git tag prove that a document hasn't changed since a commit. They don't prove when it was
  written:** commit and tag dates can be set to anything. Inside a project that's enough to keep prediction and
  postdiction apart for yourself.
- **An external registration or deposit proves timing to someone else.** Do it at freeze time, when the
  timing of a plan will be claimed to anyone outside the project (a reviewer, a journal, a reader of a result).
- **Keep the hash beside the external identifier.** They prove different things; neither replaces the other.
- **Public is the irreversible direction.** Once a registration or record is public and indexed, it can't be
  taken back. Going public is a decision, recorded with its date in the project's `AGENTS.md` (or
  `CLAUDE.md`), never a side effect of a tool.

## 1. Does the project qualify? Decide per preregistration or release

Answer in order. The first row that applies decides; "both" is common.

| # | Situation | Use | Why |
|---|---|---|---|
| 1 | Exploratory, early-stage, or only for your own decisions; no one outside will be told the plan came first | **Neither.** Hash + tag. `PREREG.md` §11: "none: local git history only" | An external record adds nothing no one will check. |
| 2 | The **timing of the plan** will be claimed outside (paper, preprint, public result), and the plan must stay **private for now** | **OSF Registration, embargoed** (up to 4 years) | Timestamped and frozen now, made public later, without publishing anything today. |
| 3 | The **plan itself** is what reviewers or a journal will check (a preregistration they recognise, a Registered Report) | **OSF Registration** | In our judgement the most widely recognised home for a preregistration, with standard templates. |
| 4 | A **public GitHub repo** whose **release** (model version, tool, the code at `<EID>-prereg`) will be cited | **Zenodo, via its GitHub integration** | A DOI per release, archived automatically, with the exact code. Needs the repo to be public. |
| 5 | A **finished result, dataset, derived table or methods note** needs a DOI, and the repo is **private** | **Zenodo, manual deposit** (or the institutional repository your funder requires; §5) | The GitHub integration can't see private repos; a manual deposit publishes only what you upload. |
| 6 | The plan will be claimed outside **and** its code will be cited | **Both:** OSF Registration for the plan, Zenodo for the code release, each linking the other | The registration proves when the plan existed; the deposit makes the code that ran citable. |

Before anything becomes public, it must pass the gates in §2. If a gate fails, the answer is row 2 (embargo)
or row 1, not a public deposit.

## 2. Gates before anything is made public

1. **Intellectual property.** If a patent or other filing is intended, it is filed first. Public disclosure can
   bar it.
2. **People.** Data from anyone other than the author needs their consent and appropriate de-identification,
   and whatever ethics approval the work is under.
3. **Authorship.** Text registered or deposited under the author's name is the author's. A preprint server may
   refuse text that is mostly machine-generated (OSF Preprints does); disclose AI assistance in every record.
4. **Third-party licences.** Data or code from others goes in only if its licence allows redistribution, with
   attribution. A source that declares no licence is shared only as derived statistics, never as data.

## 3. OSF Registration

- **Register it; don't upload it.** A document uploaded to an OSF *Project* is a file in that project, not a
  Registration: it isn't frozen, isn't timestamped as a registration, and doesn't appear in OSF Registries.
  Use the Registration workflow.
- **OSF Projects become read-only on 19 February 2027**, and new Projects can't be created after that.
  Registrations are separate records and are unaffected. Don't build a workflow on OSF Projects.

**Steps**

1. Freeze first, as `PREREG_PROTOCOL.md` requires: complete `PREREG.md`, commit, tag `<EID>-prereg`.
2. On OSF, start a Registration. Pick the template closest to the work: the general OSF Preregistration
   template; the secondary-data template for analyses of existing data; for simulations, whichever is closer,
   with `PREREG.md` attached.
3. Fill the template **from** `PREREG.md`; don't write a second plan. Attach `PREREG.md`, and record the tag
   name, its commit hash and the `ENV.lock` sha256 in the registration.
4. Choose **public** or **embargo** (up to four years; it can be ended early). Submit.
5. Record the registration's DOI or URL in `EXPERIMENTS.md` (Archive column), beside the hash (§6).

## 4. Zenodo

Zenodo gives each deposit a DOI and, for a series of versions, a *concept* DOI that always resolves to the
latest one. **Owners can delete a published record only within 30 days;** after that it can only be withdrawn,
which leaves a tombstone page at the DOI. Treat publishing as permanent.

### 4a. From GitHub releases (public repositories only)

1. **Metadata.** Add `.zenodo.json` at the repository root before the first release. Zenodo uses it in
   preference to `CITATION.cff`, whose conversion is strict: this kit's own first attempt, from a
   `CITATION.cff` with two licenses and a group author, failed. Keep it minimal:

   ```json
   {
     "title": "<Project name>",
     "upload_type": "software",
     "description": "<One paragraph: what it is and what the release contains.>",
     "creators": [
       {"name": "<Family>, <Given>", "orcid": "<0000-0000-0000-0000>"}
     ],
     "license": "<one identifier from Zenodo's license list, e.g. mit or cc-by-4.0>",
     "keywords": ["preregistration", "reproducibility"]
   }
   ```

   One license only: the one covering what people will cite. Full terms stay in `LICENSE`.
2. **Switch the repository on.** Sign in at zenodo.org with GitHub, open
   <https://zenodo.org/account/settings/github/>, and turn the repository on (**Sync now** if it isn't
   listed; for an organisation's repository, an owner may need to approve Zenodo's access). This installs a
   webhook that reacts only to releases published after it is on.
3. **Protect the tags** (a GitHub ruleset on `v*` and `*-prereg`), so an archived tag can't later be moved
   away from what was deposited.
4. **Release.** Tag and push, then `gh release create <tag> --notes-file <notes> --verify-tag`.
5. **Check.** On the Zenodo GitHub page, the release should turn green with a DOI within minutes. If it shows
   **Failed**, the reason is under **Errors** (the **Citation File** tab is a generic example, not your file).
   With protected tags a failed release can't be retried under the same tag: fix the metadata and release the
   next version.
6. **Stop** by turning the repository off there, or deleting the Zenodo webhook in the GitHub repository's
   settings. Published records stay.

### 4b. Manual deposit (private repositories, results, data, notes)

1. **Rehearse on the sandbox** (<https://sandbox.zenodo.org>, a separate account) until the record looks right.
2. **Choose the record type:** software for a tool or model release, dataset for data or derived tables,
   publication (working paper, report) for a methods note or a negative result.
3. **Reserve the DOI** before publishing if the files should cite it ("Get a DOI now!" in the upload form).
4. **Upload only what passes §2.** A private repository's history doesn't come along; state in the record's
   description which repository, tag and commit the files came from.
5. **Versions:** publish later updates as new versions of the same record, so the concept DOI keeps pointing
   at the latest.
6. **Publish only after an explicit decision by the owner.** Tools must never publish without it.

## 5. Funder and institutional repositories

Some funders and institutions require or recommend their own repository for data and outputs (for example,
Borealis, the Canadian Dataverse, for work under a UVic affiliation or Tri-Agency funding). Where one applies,
deposit data there, and use Zenodo for code releases unless the funder says otherwise. Record which applies in
the project's `AGENTS.md`.

## 6. Recording the identifier

| What | Where it goes |
|---|---|
| OSF Registration DOI or URL | The experiment's row in `EXPERIMENTS.md` (Archive column), and `RESULTS.md`. |
| Zenodo DOI for `<EID>-prereg` | Same. |
| Zenodo concept DOI for software | `doi:` in `CITATION.cff`, and a DOI badge in the README. |
| The hash | Stays where it is (tag, receipt, `ENV.lock` sha256), beside the identifier. |

A frozen `PREREG.md` can't contain an identifier that only exists after it is frozen. So §11 names the route
before tagging ("OSF Registration, embargoed until <date>", "Zenodo, from the GitHub release of
`<EID>-prereg`"), and the identifier is recorded afterwards as above. (A manual Zenodo deposit can reserve its
DOI in advance, but the deposit still happens after the freeze.)

---

## Sources

Checked 2026-09-25. Platform policies change; re-check before relying on a date or limit.

- OSF: [Registration questions for the OSF Projects transition](https://help.osf.io/article/768-osf-projects-transition-registration-questions-and-use-cases)
  (Projects read-only on 19 February 2027; a file in a Project is not a Registration);
  [Registrations & Preregistrations](https://help.osf.io/article/330-welcome-to-registrations) (embargo up to
  four years; DOI).
- Zenodo: [Enable a repository](https://help.zenodo.org/docs/github/enable-repository/) (public repositories
  only; organisation approval); [Manage records](https://help.zenodo.org/docs/deposit/manage-records/)
  (deletion by the owner within 30 days); [Can I delete my record after publishing?](https://support.zenodo.org/help/en-gb/1-upload-deposit/215-can-i-delete-my-record-after-publishing)
  (withdrawal and tombstone pages); [Reserve a DOI](https://help.zenodo.org/docs/deposit/describe-records/reserve-doi/).
