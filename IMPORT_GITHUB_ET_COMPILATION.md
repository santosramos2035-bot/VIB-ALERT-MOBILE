# Import GitHub et compilation — instructions simples

## Important

Le dépôt GitHub doit être **privé**. Ce paquet ne contient pas la clé privée Firebase du serveur, mais un dépôt privé reste préférable.

## Remplacer le dépôt actuel

1. Dans GitHub, ouvrir le dépôt `VIB-ALERT`.
2. Aller dans **Settings > General**.
3. Descendre à **Danger Zone** puis supprimer le dépôt actuel, ou créer un nouveau dépôt privé nommé `VIB-ALERT-MOBILE`.
4. Décompresser ce ZIP sur l'ordinateur.
5. Dans le nouveau dépôt, cliquer sur **Add file > Upload files**.
6. Importer les trois éléments visibles à la racine :
   - `.github`
   - `mobile`
   - `.gitignore`, `README.md` et ce guide
7. Valider avec **Commit changes**.

## Compiler

1. Cliquer sur **Actions**.
2. Ouvrir **Compiler VIB Alert Android**.
3. Cliquer sur **Run workflow**, puis encore sur le bouton vert.
4. Attendre environ 5 à 15 minutes.
5. Quand une coche verte apparaît, ouvrir le résultat.
6. En bas, dans **Artifacts**, télécharger `VIB-Alert-Android-V5.4.2`.
7. Décompresser le fichier et installer `app-release.apk`.

## Avant le test

1. Désinstaller l'ancienne application VIB Alert.
2. Installer le nouvel APK.
3. Autoriser les notifications.
4. Autoriser les alertes plein écran si Android le demande.
5. Désactiver l'optimisation de batterie pour VIB Alert.
6. Se reconnecter dans l'application afin d'enregistrer le nouveau jeton Firebase.
7. Appuyer sur **TESTER**.
