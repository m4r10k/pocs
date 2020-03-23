alias k=kubectl

eval "$(ssh-agent -s)"
ssh-add ~/.ssh/github_rsa
ssh -T git@github.com

ssh-add ~/.ssh/google_compute_engine