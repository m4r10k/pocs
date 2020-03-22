eval "$(ssh-agent -s)"
ssh-add ~/.ssh/github_rsa
ssh -T git@github.com