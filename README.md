# deploy-to-socrat

Reusable workflow that records a release in `alchemmist/homelab`. It changes `image.tag` and `image.digest` in that application's values and pushes the commit to `main`. Argo CD rolls out the commit. The workflow does not call the Argo CD API.

```yaml
deploy:
  needs: publish
  uses: alchemmist/deploy-to-socrat/.github/workflows/deploy.yml@v1
  with:
    image_version: ${{ needs.publish.outputs.digest }}
```

`image_version` accepts `sha256:<64 hex>` or an image tag. The application name defaults to the calling repository. Pass `app` when those differ.

A digest sets `image.digest` and sets `image.tag` to the calling commit. A tag sets `image.tag` and clears `image.digest`. The values file is `deploy/<app>/values.yaml`. `charts/<app>/values.yaml` is updated too when it exists.

The homelab write key is a deploy key stored only as `HOMELAB_DEPLOY_KEY` in this repository. Calling workflows do not receive it. The workflow refuses any app name other than the directory it is allowed to edit, and it only stages those values files.
