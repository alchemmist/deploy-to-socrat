# deploy-to-socrat

GitHub Action that rolls a Socrat application forward by setting its image on the Argo CD Application. Callers pass a token and an image digest or tag. The cluster rollout stays with Argo CD.

```yaml
- name: Deploy to Socrat
  uses: alchemmist/deploy-to-socrat@v1
  with:
    token: ${{ secrets.ARGOCD_AUTH_TOKEN }}
    image_version: ${{ steps.image.outputs.digest }}
```

`image_version` accepts `sha256:<64 hex>` (written to Helm `image.digest`) or an image tag (written to `image.tag`). The application name defaults to the repository name. Override it with `app` when those differ. `server` defaults to `https://argocd.socrat.alchemmist.xyz`.

If this build's commit is no longer the tip of the branch, the action exits successfully and leaves the Application unchanged.
