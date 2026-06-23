# Setting up VSCode, Git, Claude Code, and GitHub SSH

**PowerShell Setup Guide**

## 1. Install Visual Studio Code
```powershell
winget install Microsoft.VisualStudioCode
```

*Restart your terminal after installation*

## 2. Install Git
```powershell
winget install Git.Git
```

*Restart your terminal*

### Basic Git Configuration:
```powershell
git config --global user.name "Your Name"
git config --global user.email "your.email@example.com"
git config --global core.autocrlf true
git config --global init.defaultBranch main
```

## 3. Generate SSH Key for GitHub
```powershell
ssh-keygen -t ed25519 -C "your.email@example.com"
```

- Press Enter to accept default location: `C:\Users\YourName\.ssh\id_ed25519`
- Enter a passphrase (recommended) or press Enter for no passphrase

## 4. Start SSH Agent and Add Key
```powershell
# Start ssh-agent in background
Start-Service ssh-agent

# Set service to start automatically
Set-Service -Name ssh-agent -StartupType Automatic

# Add your SSH key
ssh-add ~\.ssh\id_ed25519
```

## 5. Copy Public Key to Clipboard
```powershell
# Copy to clipboard
Get-Content ~\.ssh\id_ed25519.pub | Set-Clipboard

# Or display it to copy manually
cat ~\.ssh\id_ed25519.pub
```

## 6. Add SSH Key to GitHub

1. Go to **https://github.com/settings/keys**
2. Click **"New SSH key"**
3. Add a descriptive title (e.g., "Work Laptop - PowerShell")
4. Paste your key (from clipboard)
5. Click **"Add SSH key"**

## 7. Test GitHub Connection
```powershell
ssh -T git@github.com
```

You should see: `"Hi username! You've successfully authenticated..."`

## 8. Configure Git to Use SSH

### For new clones, use SSH URLs:
```powershell
git clone git@github.com:username/repo.git
```

### For existing repos, switch from HTTPS to SSH:
```powershell
git remote set-url origin git@github.com:username/repo.git

# Verify
git remote -v
```

## 9. Create a New Repository (as Organization Member)

### On GitHub:

1. Go to your organization's page: **https://github.com/your-org**
2. Click **"Repositories"** tab
3. Click **"New repository"**
4. Fill in:
   - Repository name
   - Description (optional)
   - Choose Public or Private
   - **Do NOT** initialize with README (we'll do this locally)
5. Click **"Create repository"**

### Locally:
```powershell
# Create and navigate to your project directory
mkdir my-project
cd my-project

# Initialize Git repository
git init

# Create initial files
echo "# My Project" > README.md

# Stage and commit
git add .
git commit -m "Initial commit"

# Add remote (use SSH URL from GitHub)
git remote add origin git@github.com:your-org/my-project.git

# Push to GitHub
git branch -M main
git push -u origin main
```

## 10. Install Node.js
```powershell
winget install OpenJS.NodeJS.LTS
```

*Restart your terminal*

## 11. Install Claude Code
```powershell
npm install -g @anthropic-ai/claude-code
```

## 12. Authenticate Claude Code
```powershell
claude-code auth login
```

Follow browser prompts to log in to Claude

## Verify Everything
```powershell
code --version
git --version
node --version
ssh -T git@github.com
claude-code --version
```

## Troubleshooting SSH Agent on Windows

If ssh-agent won't start, run as Administrator:
```powershell
Get-Service ssh-agent | Set-Service -StartupType Automatic -PassThru | Start-Service
```