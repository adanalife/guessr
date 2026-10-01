// The page's words in the player's language. English is the source: every
// key below is the English string as it appears in index.html or in the game's
// script, and a language table maps it to its own wording. A key with no row
// stays English, so a missing translation costs one line rather than a blank.
//
// Two kinds of string. Markup carries `data-i18n` on the element whose inner
// HTML is the key, or `data-i18n-attr="title aria-label"` naming the
// attributes to translate; translatePage() walks both once at load. The script
// calls t() for anything it builds itself, with `{name}` slots for the parts
// that vary. test_i18n.mjs checks that every key on the page and in the script
// has a row in every table.
//
// The language is the browser's, by the two-letter prefix of the first entry
// in navigator.languages that a table exists for. `?lang=fr` overrides it, so a
// translation can be checked without changing the browser.
//
// A module, like the rest of the page's script, so it is deferred and the
// English paints first for a moment on a translated page. ponytail: an inline
// classic script in <head> would translate before first paint, at the cost of
// the tables not being importable by the test.

export const STRINGS = {
  fr: {
    // Markup.
    'Daily': 'Du jour',
    'Round': 'Manche',
    'Score': 'Score',
    'about': 'à propos',
    'Every round is a few seconds of real dashcam footage, filmed on a year-long drive around the United States in 2018. Five rounds a day, the same five for everyone. Practice rounds are unlimited.':
      'Chaque manche est quelques secondes de vraies images de dashcam, filmées lors d\'un an de route à travers les États-Unis en 2018. Cinq manches par jour, les mêmes pour tout le monde. Les manches d\'entraînement sont illimitées.',
    'Pause the clip with the pause button or spacebar. Zoom in and look for clues.':
      'Mettez le clip en pause avec le bouton pause ou la barre d\'espace. Zoomez et cherchez des indices.',
    'All of the footage comes from the <a href="https://dana.lol">A Dana Life</a> project, a livestream that streams the trip 24/7. It\'s available on several platforms, some of which have more games you can play.':
      'Toutes les images viennent du projet <a href="https://dana.lol">A Dana Life</a>, un direct qui diffuse le voyage 24h/24. Il est disponible sur plusieurs plateformes, dont certaines proposent d\'autres jeux.',
    'Watch on YouTube': 'Regarder sur YouTube',
    'Guess in realtime on Twitch': 'Deviner en direct sur Twitch',
    'Your leaderboard name is': 'Votre nom au classement est',
    'Generate new name': 'Générer un nouveau nom',
    'Draw another name': 'Tirer un autre nom',
    'Undo': 'Annuler',
    'Go back to the name before the last reroll': 'Revenir au nom d\'avant le dernier tirage',
    'Link a device': 'Lier un appareil',
    'Show a code that adds another device\'s scores to yours': 'Afficher un code qui ajoute les scores d\'un autre appareil aux vôtres',
    'Have a code from another device?': 'Vous avez un code d\'un autre appareil ?',
    'Join': 'Rejoindre',
    'Running': 'Version',
    'Reset saved state': 'Réinitialiser l\'état enregistré',
    'Dashcam footage ©&nbsp;A Dana Life, all rights reserved': 'Images de dashcam ©&nbsp;A Dana Life, tous droits réservés',
    'Drop a pin where you think this clip was filmed': 'Placez un repère là où vous pensez que ce clip a été filmé',
    'This is real footage from a year of traveling in a campervan': 'Ce sont de vraies images d\'un an de voyage en van',
    'Every player guesses the same 5 clips, new ones daily': 'Tous les joueurs devinent les mêmes 5 clips, renouvelés chaque jour',
    'Play': 'Jouer',
    'Learn more': 'En savoir plus',
    'A few seconds of dashcam footage to locate': 'Quelques secondes de dashcam à localiser',
    'Zoom in, or scroll, pinch, or double-click the frame': 'Zoom avant, ou molette, pincement ou double-clic sur l\'image',
    'Zoom in': 'Zoom avant',
    'Zoom out': 'Zoom arrière',
    'Pause, or press space': 'Pause, ou touche espace',
    'Pause': 'Pause',
    'Back to all five rounds, or press Escape': 'Retour aux cinq manches, ou touche Échap',
    'Back to all five rounds': 'Retour aux cinq manches',
    'The map is having trouble loading. You can still drop a pin — the grid is the same.': 'La carte a du mal à charger. Vous pouvez quand même placer un repère — la grille est la même.',
    'Drop a pin to guess': 'Placez un repère pour répondre',
    'Place random': 'Point aléatoire',
    'Guess a random point and move on': 'Deviner un point au hasard et passer à la suite',
    'Share': 'Partager',
    'Practice': 'Entraînement',
    'All my guesses': 'Toutes mes réponses',
    'Somewhere in the United States. Where?': 'Quelque part aux États-Unis. Où ?',
    'Toggle dark mode': 'Basculer le mode sombre',
    // Script.
    'Guess': 'Deviner',
    'Scoring…': 'Calcul du score…',
    'Practice rounds': 'Manches d\'entraînement',
    '{error}. Practice rounds still work.': '{error}. Les manches d\'entraînement fonctionnent toujours.',
    'Could not reach the scorer. Try that guess again.': 'Impossible de joindre le serveur de score. Réessayez cette réponse.',
    '<b>{state}</b>, {filmed} — you were off by <b>{miles} mi</b> for <b>{pts}</b> points.': '<b>{state}</b>, {filmed} — vous étiez à <b>{miles} mi</b>, soit <b>{pts}</b> points.',
    'Next round': 'Manche suivante',
    'Could not reach the rounds': 'Impossible de charger les manches',
    '<b>{n}</b> rounds — {daily}<b>{d} daily</b>, {practice}<b>{p} practice</b>. Each line runs from your guess to the truth.': '<b>{n}</b> manches — {daily}<b>{d} du jour</b>, {practice}<b>{p} d\'entraînement</b>. Chaque ligne va de votre réponse à la vraie position.',
    'Watch round {n} again': 'Revoir la manche {n}',
    'Round {n}': 'Manche {n}',
    'Watch live on YouTube →': 'Regarder en direct sur YouTube →',
    'A Dana Life: the 24/7 dashcam stream, live on YouTube': 'A Dana Life : le direct dashcam 24h/24, en live sur YouTube',
    'Play again': 'Rejouer',
    'Back to today\'s': 'Retour à la partie du jour',
    'Daily #{n}': 'Jour #{n}',
    'Today\'s round is done — {score}. Come back tomorrow, or play practice rounds.': 'La partie du jour est terminée — {score}. Revenez demain, ou jouez des manches d\'entraînement.',
    'Copied': 'Copié',
    'Copy your result:': 'Copiez votre résultat :',
    'Play, or press space': 'Lecture, ou touche espace',
    'Scan from your other device to play as one player': 'Scannez depuis votre autre appareil pour jouer comme un seul joueur',
    'Link a device to play as one player': 'Lier un appareil pour jouer comme un seul joueur',
    'Or enter <b id="linkcode"></b> on the other device.': 'Ou saisissez <b id="linkcode"></b> sur l\'autre appareil.',
    'That code is unknown or has expired. Draw a new one on the other device.': 'Ce code est inconnu ou a expiré. Tirez-en un nouveau sur l\'autre appareil.',
    'Could not link the devices just now. Try the code again.': 'Impossible de lier les appareils pour le moment. Réessayez le code.',
    'This browser becomes {to} ({toPoints} points), replacing {me} ({mePoints} points). Its scores go with it. Both devices will play as one player from now on.': 'Ce navigateur devient {to} ({toPoints} points) et remplace {me} ({mePoints} points). Ses scores le suivent. Les deux appareils joueront désormais comme un seul joueur.',
    'Add this browser\'s scores to {name}? Both devices will play as one player from now on.': 'Ajouter les scores de ce navigateur à {name} ? Les deux appareils joueront désormais comme un seul joueur.',
    'your other device': 'votre autre appareil',
    'Could not link the devices just now. Open the link again to retry.': 'Impossible de lier les appareils pour le moment. Rouvrez le lien pour réessayer.',
  },
  es: {
    'Daily': 'Diaria',
    'Round': 'Ronda',
    'Score': 'Puntos',
    'about': 'acerca de',
    'Every round is a few seconds of real dashcam footage, filmed on a year-long drive around the United States in 2018. Five rounds a day, the same five for everyone. Practice rounds are unlimited.':
      'Cada ronda son unos segundos de imágenes reales de dashcam, grabadas en un viaje de un año por Estados Unidos en 2018. Cinco rondas al día, las mismas para todos. Las rondas de práctica son ilimitadas.',
    'Pause the clip with the pause button or spacebar. Zoom in and look for clues.':
      'Pausa el clip con el botón de pausa o la barra espaciadora. Haz zoom y busca pistas.',
    'All of the footage comes from the <a href="https://dana.lol">A Dana Life</a> project, a livestream that streams the trip 24/7. It\'s available on several platforms, some of which have more games you can play.':
      'Todas las imágenes vienen del proyecto <a href="https://dana.lol">A Dana Life</a>, un directo que emite el viaje las 24 horas. Está en varias plataformas, y algunas tienen más juegos.',
    'Watch on YouTube': 'Ver en YouTube',
    'Guess in realtime on Twitch': 'Adivina en directo en Twitch',
    'Your leaderboard name is': 'Tu nombre en la clasificación es',
    'Generate new name': 'Generar un nombre nuevo',
    'Draw another name': 'Sacar otro nombre',
    'Undo': 'Deshacer',
    'Go back to the name before the last reroll': 'Volver al nombre anterior',
    'Link a device': 'Vincular un dispositivo',
    'Show a code that adds another device\'s scores to yours': 'Mostrar un código que suma a los tuyos los puntos de otro dispositivo',
    'Have a code from another device?': '¿Tienes un código de otro dispositivo?',
    'Join': 'Unirse',
    'Running': 'Versión',
    'Reset saved state': 'Restablecer el estado guardado',
    'Dashcam footage ©&nbsp;A Dana Life, all rights reserved': 'Imágenes de dashcam ©&nbsp;A Dana Life, todos los derechos reservados',
    'Drop a pin where you think this clip was filmed': 'Coloca un marcador donde crees que se grabó este clip',
    'This is real footage from a year of traveling in a campervan': 'Son imágenes reales de un año viajando en furgoneta camper',
    'Every player guesses the same 5 clips, new ones daily': 'Todos los jugadores adivinan los mismos 5 clips, nuevos cada día',
    'Play': 'Jugar',
    'Learn more': 'Más información',
    'A few seconds of dashcam footage to locate': 'Unos segundos de dashcam para ubicar',
    'Zoom in, or scroll, pinch, or double-click the frame': 'Acercar, o rueda, pellizco o doble clic en la imagen',
    'Zoom in': 'Acercar',
    'Zoom out': 'Alejar',
    'Pause, or press space': 'Pausar, o pulsa espacio',
    'Pause': 'Pausar',
    'Back to all five rounds, or press Escape': 'Volver a las cinco rondas, o pulsa Escape',
    'Back to all five rounds': 'Volver a las cinco rondas',
    'The map is having trouble loading. You can still drop a pin — the grid is the same.': 'El mapa no termina de cargar. Aun así puedes colocar un marcador: la cuadrícula es la misma.',
    'Drop a pin to guess': 'Coloca un marcador para responder',
    'Place random': 'Punto aleatorio',
    'Guess a random point and move on': 'Adivinar un punto al azar y seguir',
    'Share': 'Compartir',
    'Practice': 'Práctica',
    'All my guesses': 'Todas mis respuestas',
    'Somewhere in the United States. Where?': 'En algún lugar de Estados Unidos. ¿Dónde?',
    'Toggle dark mode': 'Cambiar el modo oscuro',
    'Guess': 'Adivinar',
    'Scoring…': 'Puntuando…',
    'Practice rounds': 'Rondas de práctica',
    '{error}. Practice rounds still work.': '{error}. Las rondas de práctica siguen funcionando.',
    'Could not reach the scorer. Try that guess again.': 'No se pudo conectar con el servidor de puntuación. Repite esa respuesta.',
    '<b>{state}</b>, {filmed} — you were off by <b>{miles} mi</b> for <b>{pts}</b> points.': '<b>{state}</b>, {filmed} — fallaste por <b>{miles} mi</b> y sumas <b>{pts}</b> puntos.',
    'Next round': 'Siguiente ronda',
    'Could not reach the rounds': 'No se pudieron cargar las rondas',
    '<b>{n}</b> rounds — {daily}<b>{d} daily</b>, {practice}<b>{p} practice</b>. Each line runs from your guess to the truth.': '<b>{n}</b> rondas — {daily}<b>{d} diarias</b>, {practice}<b>{p} de práctica</b>. Cada línea va de tu respuesta al lugar real.',
    'Watch round {n} again': 'Ver la ronda {n} otra vez',
    'Round {n}': 'Ronda {n}',
    'Watch live on YouTube →': 'Ver en directo en YouTube →',
    'A Dana Life: the 24/7 dashcam stream, live on YouTube': 'A Dana Life: el directo de dashcam 24 horas, en vivo en YouTube',
    'Play again': 'Jugar otra vez',
    'Back to today\'s': 'Volver a la de hoy',
    'Daily #{n}': 'Diaria #{n}',
    'Today\'s round is done — {score}. Come back tomorrow, or play practice rounds.': 'La partida de hoy está hecha — {score}. Vuelve mañana o juega rondas de práctica.',
    'Copied': 'Copiado',
    'Copy your result:': 'Copia tu resultado:',
    'Play, or press space': 'Reproducir, o pulsa espacio',
    'Scan from your other device to play as one player': 'Escanea desde tu otro dispositivo para jugar como un solo jugador',
    'Link a device to play as one player': 'Vincular un dispositivo para jugar como un solo jugador',
    'Or enter <b id="linkcode"></b> on the other device.': 'O introduce <b id="linkcode"></b> en el otro dispositivo.',
    'That code is unknown or has expired. Draw a new one on the other device.': 'Ese código es desconocido o ha caducado. Saca uno nuevo en el otro dispositivo.',
    'Could not link the devices just now. Try the code again.': 'No se pudieron vincular los dispositivos ahora mismo. Prueba el código de nuevo.',
    'This browser becomes {to} ({toPoints} points), replacing {me} ({mePoints} points). Its scores go with it. Both devices will play as one player from now on.': 'Este navegador pasa a ser {to} ({toPoints} puntos) y sustituye a {me} ({mePoints} puntos). Sus puntos van con él. Ambos dispositivos jugarán como un solo jugador a partir de ahora.',
    'Add this browser\'s scores to {name}? Both devices will play as one player from now on.': '¿Sumar los puntos de este navegador a {name}? Ambos dispositivos jugarán como un solo jugador a partir de ahora.',
    'your other device': 'tu otro dispositivo',
    'Could not link the devices just now. Open the link again to retry.': 'No se pudieron vincular los dispositivos ahora mismo. Abre el enlace de nuevo para reintentar.',
  },
  ru: {
    'Daily': 'Игра дня',
    'Round': 'Раунд',
    'Score': 'Очки',
    'about': 'об игре',
    'Every round is a few seconds of real dashcam footage, filmed on a year-long drive around the United States in 2018. Five rounds a day, the same five for everyone. Practice rounds are unlimited.':
      'Каждый раунд — несколько секунд настоящей записи с видеорегистратора, снятой за год поездки по США в 2018 году. Пять раундов в день, одни и те же для всех. Тренировочные раунды не ограничены.',
    'Pause the clip with the pause button or spacebar. Zoom in and look for clues.':
      'Остановите ролик кнопкой паузы или пробелом. Приблизьте и ищите подсказки.',
    'All of the footage comes from the <a href="https://dana.lol">A Dana Life</a> project, a livestream that streams the trip 24/7. It\'s available on several platforms, some of which have more games you can play.':
      'Все записи — из проекта <a href="https://dana.lol">A Dana Life</a>, круглосуточной трансляции поездки. Она идёт на нескольких платформах, и на некоторых есть ещё игры.',
    'Watch on YouTube': 'Смотреть на YouTube',
    'Guess in realtime on Twitch': 'Угадывать в прямом эфире на Twitch',
    'Your leaderboard name is': 'Ваше имя в таблице лидеров:',
    'Generate new name': 'Сгенерировать новое имя',
    'Draw another name': 'Выбрать другое имя',
    'Undo': 'Отменить',
    'Go back to the name before the last reroll': 'Вернуть прежнее имя',
    'Link a device': 'Привязать устройство',
    'Show a code that adds another device\'s scores to yours': 'Показать код, который добавит очки другого устройства к вашим',
    'Have a code from another device?': 'Есть код с другого устройства?',
    'Join': 'Присоединиться',
    'Running': 'Версия',
    'Reset saved state': 'Сбросить сохранённое состояние',
    'Dashcam footage ©&nbsp;A Dana Life, all rights reserved': 'Записи с видеорегистратора ©&nbsp;A Dana Life, все права защищены',
    'Drop a pin where you think this clip was filmed': 'Поставьте метку там, где, по-вашему, снят этот ролик',
    'This is real footage from a year of traveling in a campervan': 'Это настоящие записи из года путешествий в автодоме',
    'Every player guesses the same 5 clips, new ones daily': 'Все игроки угадывают одни и те же 5 роликов, каждый день новые',
    'Play': 'Играть',
    'Learn more': 'Подробнее',
    'A few seconds of dashcam footage to locate': 'Несколько секунд записи с видеорегистратора, место которой нужно найти',
    'Zoom in, or scroll, pinch, or double-click the frame': 'Приблизить — или колёсико, щипок, двойной клик по кадру',
    'Zoom in': 'Приблизить',
    'Zoom out': 'Отдалить',
    'Pause, or press space': 'Пауза, или нажмите пробел',
    'Pause': 'Пауза',
    'Back to all five rounds, or press Escape': 'Назад ко всем пяти раундам, или нажмите Escape',
    'Back to all five rounds': 'Назад ко всем пяти раундам',
    'The map is having trouble loading. You can still drop a pin — the grid is the same.': 'Карта не загружается. Метку всё равно можно поставить — сетка та же.',
    'Drop a pin to guess': 'Поставьте метку, чтобы ответить',
    'Place random': 'Случайная точка',
    'Guess a random point and move on': 'Ответить случайной точкой и перейти дальше',
    'Share': 'Поделиться',
    'Practice': 'Тренировка',
    'All my guesses': 'Все мои ответы',
    'Somewhere in the United States. Where?': 'Где-то в США. Где?',
    'Toggle dark mode': 'Переключить тёмную тему',
    'Guess': 'Ответить',
    'Scoring…': 'Подсчёт…',
    'Practice rounds': 'Тренировочные раунды',
    '{error}. Practice rounds still work.': '{error}. Тренировочные раунды по-прежнему доступны.',
    'Could not reach the scorer. Try that guess again.': 'Не удалось связаться с сервером подсчёта. Попробуйте ответить ещё раз.',
    '<b>{state}</b>, {filmed} — you were off by <b>{miles} mi</b> for <b>{pts}</b> points.': '<b>{state}</b>, {filmed} — промах на <b>{miles} миль</b>, <b>{pts}</b> очков.',
    'Next round': 'Следующий раунд',
    'Could not reach the rounds': 'Не удалось загрузить раунды',
    '<b>{n}</b> rounds — {daily}<b>{d} daily</b>, {practice}<b>{p} practice</b>. Each line runs from your guess to the truth.': '<b>{n}</b> раундов — {daily}<b>{d} игры дня</b>, {practice}<b>{p} тренировки</b>. Каждая линия идёт от вашего ответа к настоящему месту.',
    'Watch round {n} again': 'Пересмотреть раунд {n}',
    'Round {n}': 'Раунд {n}',
    'Watch live on YouTube →': 'Смотреть в прямом эфире на YouTube →',
    'A Dana Life: the 24/7 dashcam stream, live on YouTube': 'A Dana Life: круглосуточная трансляция с видеорегистратора на YouTube',
    'Play again': 'Сыграть ещё',
    'Back to today\'s': 'Назад к игре дня',
    'Daily #{n}': 'День #{n}',
    'Today\'s round is done — {score}. Come back tomorrow, or play practice rounds.': 'Игра дня пройдена — {score}. Возвращайтесь завтра или сыграйте тренировочные раунды.',
    'Copied': 'Скопировано',
    'Copy your result:': 'Скопируйте результат:',
    'Play, or press space': 'Воспроизвести, или нажмите пробел',
    'Scan from your other device to play as one player': 'Отсканируйте с другого устройства, чтобы играть как один игрок',
    'Link a device to play as one player': 'Привязать устройство, чтобы играть как один игрок',
    'Or enter <b id="linkcode"></b> on the other device.': 'Или введите <b id="linkcode"></b> на другом устройстве.',
    'That code is unknown or has expired. Draw a new one on the other device.': 'Код неизвестен или истёк. Получите новый на другом устройстве.',
    'Could not link the devices just now. Try the code again.': 'Не удалось привязать устройства. Попробуйте ввести код ещё раз.',
    'This browser becomes {to} ({toPoints} points), replacing {me} ({mePoints} points). Its scores go with it. Both devices will play as one player from now on.': 'Этот браузер становится {to} ({toPoints} очков) вместо {me} ({mePoints} очков). Его очки переходят вместе с ним. Оба устройства теперь играют как один игрок.',
    'Add this browser\'s scores to {name}? Both devices will play as one player from now on.': 'Добавить очки этого браузера к {name}? Оба устройства теперь будут играть как один игрок.',
    'your other device': 'вашему другому устройству',
    'Could not link the devices just now. Open the link again to retry.': 'Не удалось привязать устройства. Откройте ссылку ещё раз, чтобы повторить.',
  },
  cs: {
    'Daily': 'Denní',
    'Round': 'Kolo',
    'Score': 'Skóre',
    'about': 'o hře',
    'Every round is a few seconds of real dashcam footage, filmed on a year-long drive around the United States in 2018. Five rounds a day, the same five for everyone. Practice rounds are unlimited.':
      'Každé kolo je pár vteřin skutečného záznamu z palubní kamery, natočeného během roční cesty po Spojených státech v roce 2018. Pět kol denně, pro všechny stejných. Tréninková kola jsou bez omezení.',
    'Pause the clip with the pause button or spacebar. Zoom in and look for clues.':
      'Klip pozastavíte tlačítkem pauzy nebo mezerníkem. Přibližte si ho a hledejte stopy.',
    'All of the footage comes from the <a href="https://dana.lol">A Dana Life</a> project, a livestream that streams the trip 24/7. It\'s available on several platforms, some of which have more games you can play.':
      'Všechny záběry pocházejí z projektu <a href="https://dana.lol">A Dana Life</a>, nonstop živého přenosu z cesty. Běží na několika platformách a na některých najdete další hry.',
    'Watch on YouTube': 'Sledovat na YouTube',
    'Guess in realtime on Twitch': 'Hádat živě na Twitchi',
    'Your leaderboard name is': 'Vaše jméno v žebříčku je',
    'Generate new name': 'Vygenerovat nové jméno',
    'Draw another name': 'Vylosovat jiné jméno',
    'Undo': 'Zpět',
    'Go back to the name before the last reroll': 'Vrátit se k předchozímu jménu',
    'Link a device': 'Propojit zařízení',
    'Show a code that adds another device\'s scores to yours': 'Zobrazit kód, který k vašemu skóre přidá skóre z jiného zařízení',
    'Have a code from another device?': 'Máte kód z jiného zařízení?',
    'Join': 'Připojit',
    'Running': 'Verze',
    'Reset saved state': 'Smazat uložený stav',
    'Dashcam footage ©&nbsp;A Dana Life, all rights reserved': 'Záznam z palubní kamery ©&nbsp;A Dana Life, všechna práva vyhrazena',
    'Drop a pin where you think this clip was filmed': 'Umístěte špendlík tam, kde byl podle vás tento klip natočen',
    'This is real footage from a year of traveling in a campervan': 'Jsou to skutečné záběry z roku cestování obytnou dodávkou',
    'Every player guesses the same 5 clips, new ones daily': 'Všichni hráči hádají stejných 5 klipů, každý den nových',
    'Play': 'Hrát',
    'Learn more': 'Zjistit více',
    'A few seconds of dashcam footage to locate': 'Pár vteřin záznamu z palubní kamery k určení místa',
    'Zoom in, or scroll, pinch, or double-click the frame': 'Přiblížit, nebo kolečko, gesto či dvojklik na obraz',
    'Zoom in': 'Přiblížit',
    'Zoom out': 'Oddálit',
    'Pause, or press space': 'Pozastavit, nebo stiskněte mezerník',
    'Pause': 'Pozastavit',
    'Back to all five rounds, or press Escape': 'Zpět na všech pět kol, nebo stiskněte Escape',
    'Back to all five rounds': 'Zpět na všech pět kol',
    'The map is having trouble loading. You can still drop a pin — the grid is the same.': 'Mapa se nenačítá. Špendlík můžete umístit i tak — mřížka je stejná.',
    'Drop a pin to guess': 'Umístěte špendlík a tipněte si',
    'Place random': 'Náhodný bod',
    'Guess a random point and move on': 'Tipnout náhodný bod a pokračovat',
    'Share': 'Sdílet',
    'Practice': 'Trénink',
    'All my guesses': 'Všechny mé tipy',
    'Somewhere in the United States. Where?': 'Někde ve Spojených státech. Kde?',
    'Toggle dark mode': 'Přepnout tmavý režim',
    'Guess': 'Tipnout',
    'Scoring…': 'Počítám…',
    'Practice rounds': 'Tréninková kola',
    '{error}. Practice rounds still work.': '{error}. Tréninková kola fungují dál.',
    'Could not reach the scorer. Try that guess again.': 'Server pro skóre je nedostupný. Zkuste tip znovu.',
    '<b>{state}</b>, {filmed} — you were off by <b>{miles} mi</b> for <b>{pts}</b> points.': '<b>{state}</b>, {filmed} — byli jste vedle o <b>{miles} mi</b>, za <b>{pts}</b> bodů.',
    'Next round': 'Další kolo',
    'Could not reach the rounds': 'Kola se nepodařilo načíst',
    '<b>{n}</b> rounds — {daily}<b>{d} daily</b>, {practice}<b>{p} practice</b>. Each line runs from your guess to the truth.': '<b>{n}</b> kol — {daily}<b>{d} denních</b>, {practice}<b>{p} tréninkových</b>. Každá čára vede od vašeho tipu ke skutečnému místu.',
    'Watch round {n} again': 'Přehrát kolo {n} znovu',
    'Round {n}': 'Kolo {n}',
    'Watch live on YouTube →': 'Sledovat živě na YouTube →',
    'A Dana Life: the 24/7 dashcam stream, live on YouTube': 'A Dana Life: nonstop přenos z palubní kamery, živě na YouTube',
    'Play again': 'Hrát znovu',
    'Back to today\'s': 'Zpět na dnešní',
    'Daily #{n}': 'Den #{n}',
    'Today\'s round is done — {score}. Come back tomorrow, or play practice rounds.': 'Dnešní hra je hotová — {score}. Vraťte se zítra, nebo si zahrajte tréninková kola.',
    'Copied': 'Zkopírováno',
    'Copy your result:': 'Zkopírujte svůj výsledek:',
    'Play, or press space': 'Přehrát, nebo stiskněte mezerník',
    'Scan from your other device to play as one player': 'Naskenujte z druhého zařízení a hrajte jako jeden hráč',
    'Link a device to play as one player': 'Propojit zařízení a hrát jako jeden hráč',
    'Or enter <b id="linkcode"></b> on the other device.': 'Nebo na druhém zařízení zadejte <b id="linkcode"></b>.',
    'That code is unknown or has expired. Draw a new one on the other device.': 'Kód je neznámý nebo vypršel. Vygenerujte si na druhém zařízení nový.',
    'Could not link the devices just now. Try the code again.': 'Zařízení se teď nepodařilo propojit. Zkuste kód znovu.',
    'This browser becomes {to} ({toPoints} points), replacing {me} ({mePoints} points). Its scores go with it. Both devices will play as one player from now on.': 'Tento prohlížeč se stane {to} ({toPoints} bodů) a nahradí {me} ({mePoints} bodů). Jeho skóre jde s ním. Obě zařízení odteď hrají jako jeden hráč.',
    'Add this browser\'s scores to {name}? Both devices will play as one player from now on.': 'Přidat skóre tohoto prohlížeče k {name}? Obě zařízení odteď hrají jako jeden hráč.',
    'your other device': 'vašemu druhému zařízení',
    'Could not link the devices just now. Open the link again to retry.': 'Zařízení se teď nepodařilo propojit. Otevřete odkaz znovu a zkuste to.',
  },
};

export const LANGUAGES = Object.keys(STRINGS);

// The first browser language a table exists for, by its two-letter prefix;
// English when none is. `?lang=` wins when it names a table.
export function pickLanguage(preferred, query = '') {
  const asked = new URLSearchParams(query).get('lang');
  if (asked && STRINGS[asked]) return asked;
  for (const tag of preferred) {
    const lang = tag.slice(0, 2).toLowerCase();
    if (STRINGS[lang]) return lang;
  }
  return 'en';
}

export const LANG = pickLanguage(globalThis.navigator?.languages ?? [], globalThis.location?.search);

// The string for `key` in the page's language, English when there is no row,
// with each `{name}` filled from `vars`.
export function t(key, vars = {}) {
  let out = STRINGS[LANG]?.[key] ?? key;
  for (const [name, value] of Object.entries(vars)) out = out.replaceAll(`{${name}}`, value);
  return out;
}

// Rewrites every marked element and attribute in place. Whitespace inside a
// key collapses to single spaces, so the markup can wrap a sentence freely.
export function translatePage(root = document) {
  if (LANG === 'en') return;
  root.documentElement.lang = LANG;
  for (const node of root.querySelectorAll('[data-i18n]')) {
    node.innerHTML = t(node.innerHTML.replace(/\s+/g, ' ').trim());
  }
  for (const node of root.querySelectorAll('[data-i18n-attr]')) {
    for (const attr of node.dataset.i18nAttr.split(' ')) node.setAttribute(attr, t(node.getAttribute(attr)));
  }
}
