# Catalogo AG iOS — Test 1

Minimal SwiftUI app to test loading an unsigned IPA in LiveContainer.

## Build
1. Create a **private** GitHub repository named `CatalogoAG-iOS` (do not initialize it with files).
2. Upload all files from this folder, preserving `.github/workflows/build.yml`.
3. Open the repository's **Actions** tab, choose **Build unsigned iOS IPA**, and select **Run workflow** (or push to main).
4. When the workflow succeeds, download the `CatalogoAG-unsigned` artifact. Unzip the GitHub artifact to find `CatalogoAG-unsigned.ipa`.
5. Import the IPA into LiveContainer and try launching it.

This IPA is **unsigned**, intended only for compatibility testing with LiveContainer. It cannot be installed directly on iOS without appropriate signing. LiveContainer compatibility is not guaranteed.

## Notes
- The current build contains demonstration content only. No Google Sheets or TMDb credentials are included.
- Build requires GitHub-hosted macOS runner availability and suitable Actions quota.
