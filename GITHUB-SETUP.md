# GitHub Setup

1. Create a public GitHub repository named `jkelts-check`.

2. Replace `YOUR-GITHUB-USERNAME` in:
   - `jk.ps1`
   - `jk-cpu.ps1`

3. Build the release ZIP:

```powershell
powershell -ExecutionPolicy Bypass -File .\build-release.ps1
```

4. Upload the project files to GitHub.

5. Create a GitHub Release and upload:

```text
out\jkelts-check.zip
```

6. Run from another PC:

```powershell
irm https://raw.githubusercontent.com/YOUR-GITHUB-USERNAME/jkelts-check/main/jk.ps1 | iex
```

CPU-only:

```powershell
irm https://raw.githubusercontent.com/YOUR-GITHUB-USERNAME/jkelts-check/main/jk-cpu.ps1 | iex
```
