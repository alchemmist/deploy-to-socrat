# deploy-to-socrat

GitHub Action that records a release in `alchemmist/homelab`. It updates `image.tag` and `image.digest` for one application and pushes that commit to `main`. Argo CD syncs the repository on its own.

```yaml
- name: Deploy to Socrat
  uses: alchemmist/deploy-to-socrat@v1
  with:
    token: ${{ secrets.HOMELAB_DEPLOY_KEY }}
    image_version: ${{ steps.image.outputs.digest }}
```

`image_version` accepts `sha256:<64 hex>` or an image tag. The application name defaults to the repository name. Pass `app` when those differ.

A digest sets `image.digest` and sets `image.tag` to the calling commit. A tag sets `image.tag` and clears `image.digest`. The file is `deploy/<app>/values.yaml`. `charts/<app>/values.yaml` is updated too when it exists.

Pass `component` when one application publishes several images, such as `front`. The matching block must already contain `tag` and `digest`.

`token` is a write deploy key for `alchemmist/homelab`. The action stages only that application's values files.
