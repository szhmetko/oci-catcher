#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# catch.sh — ловилка свободной ёмкости Oracle Cloud Always Free.
# Версия для GitHub Actions: вся конфигурация приходит через переменные
# окружения (из secrets), ничего не читается из файлов репозитория.
#
# Отличия от локальной версии:
#   * OCID образов и подсети резолвятся на старте прогона, а не хранятся
#     в конфиге — нечему протухнуть и нечего забыть заполнить;
#   * защита от второго инстанса — запрос к API, а не файл-флаг на диске
#     (в CI диск между прогонами не переживает);
#   * прогон сам завершается по дедлайну, не дожидаясь, пока GitHub убьёт
#     job по лимиту в 6 часов;
#   * штраф за rate limit нарастающий и спадающий, а не фиксированные 5 минут.
# ---------------------------------------------------------------------------
set -Eeuo pipefail

: "${OCI_COMPARTMENT_ID:?не задан}"
: "${SSH_PUBKEY:?не задан}"

DEADLINE_MIN="${DEADLINE_MIN:-340}"     # меньше лимита GitHub в 360 минут
ATTEMPT_GAP="${ATTEMPT_GAP:-35}"        # пауза между попытками внутри круга
ROUND_GAP_MIN="${ROUND_GAP_MIN:-40}"
ROUND_GAP_MAX="${ROUND_GAP_MAX:-80}"
INSTANCE_NAME="${INSTANCE_NAME:-freqtrade}"
BOOT_GB="${BOOT_GB:-50}"
UBUNTU_VERSION="${UBUNTU_VERSION:-24.04}"

END_TS=$(( $(date +%s) + DEADLINE_MIN * 60 ))

log() { printf '%s  %s\n' "$(date -u '+%F %T')" "$*"; }

notify() {
  log "$1"
  [[ -n "${TG_TOKEN:-}" && -n "${TG_CHAT_ID:-}" ]] || return 0
  curl -sS -m 15 -X POST "https://api.telegram.org/bot${TG_TOKEN}/sendMessage" \
    -d chat_id="${TG_CHAT_ID}" \
    --data-urlencode "text=$1" >/dev/null || log "Telegram: отправить не удалось"
}

expired() { (( $(date +%s) >= END_TS )); }

# --- Защита от второго инстанса --------------------------------------------
# Квота Always Free невелика, и поймать второй инстанс поверх уже пойманного
# значит потратить её впустую. Проверяем через API, а не через файл на диске.
raw=$(oci compute instance list --compartment-id "$OCI_COMPARTMENT_ID" --all 2>/dev/null || true)
if [[ -n "$raw" ]]; then
  alive=$(jq -r '[.data[]? | select(."lifecycle-state"=="RUNNING"
                                  or ."lifecycle-state"=="PROVISIONING"
                                  or ."lifecycle-state"=="STARTING")] | length' <<<"$raw")
  if [[ "${alive:-0}" != "0" ]]; then
    log "В тенанси уже есть живой инстанс (${alive} шт.) — ловить нечего, выходим."
    exit 0
  fi
fi

# --- Availability domains ---------------------------------------------------
mapfile -t ADS < <(
  oci iam availability-domain list --compartment-id "$OCI_COMPARTMENT_ID" 2>/dev/null \
    | jq -r '.data[].name'
)
[[ ${#ADS[@]} -gt 0 ]] || { log "Не удалось получить список AD — проверь доступ"; exit 1; }
log "Availability domains: ${ADS[*]}"
(( ${#ADS[@]} == 1 )) && log "Регион однодоменный — перебор идёт только по формам."

# --- Подсеть ----------------------------------------------------------------
if [[ -z "${OCI_SUBNET_ID:-}" ]]; then
  OCI_SUBNET_ID=$(
    oci network subnet list --compartment-id "$OCI_COMPARTMENT_ID" 2>/dev/null \
      | jq -r '.data[0].id // empty'
  )
fi
[[ -n "$OCI_SUBNET_ID" ]] || { log "Не нашёл подсеть — создай её или задай OCI_SUBNET_ID"; exit 1; }
log "Подсеть: ${OCI_SUBNET_ID}"

# --- Образы -----------------------------------------------------------------
# Фильтр по --shape гарантирует нужную архитектуру: для A1 вернётся aarch64,
# для E2.1.Micro — x86_64. Руками разбирать имена образов не нужно.
resolve_image() {
  local shape="$1" ver
  for ver in "$UBUNTU_VERSION" 22.04; do
    local id
    id=$(
      oci compute image list \
        --compartment-id "$OCI_COMPARTMENT_ID" \
        --operating-system "Canonical Ubuntu" \
        --operating-system-version "$ver" \
        --shape "$shape" \
        --sort-by TIMECREATED --sort-order DESC \
        2>/dev/null | jq -r '.data[0].id // empty'
    )
    [[ -n "$id" ]] && { echo "$id"; return 0; }
  done
  return 1
}

IMAGE_AMD=$(resolve_image "VM.Standard.E2.1.Micro" || true)
IMAGE_ARM=$(resolve_image "VM.Standard.A1.Flex" || true)
log "Образ x86_64: ${IMAGE_AMD:-НЕ НАЙДЕН}"
log "Образ aarch64: ${IMAGE_ARM:-НЕ НАЙДЕН}"

# --- Очередь форм -----------------------------------------------------------
# Порядок намеренный: от самого мелкого следа к самому крупному. Планировщику
# OCI проще найти дырку под маленький инстанс, чем под непрерывный блок, и на
# фрагментированном хосте мелочь ловится заметно чаще.
#
#   1. E2.1.Micro          — фиксированная форма, 1 GB
#   2. A1.Flex 1 OCPU/1 GB — минимально возможный ARM-след (у A1 минимум
#                            памяти 1 GB на OCPU), самый вероятный к поимке
#   3. A1.Flex 1 OCPU/6 GB — половина квоты
#   4. A1.Flex 2 OCPU/12 GB — полная квота Always Free
#
# Поймав A1 любого размера, ты уже знаешь, что ARM-ёмкость на этом хосте есть,
# и расширение через Edit Shape — отдельная попытка с лучшими шансами, чем
# запуск с нуля.
#
# Формат: форма|OCPU|RAM_GB|image
TARGETS=()
[[ -n "$IMAGE_AMD" ]] && TARGETS+=("VM.Standard.E2.1.Micro|1|1|${IMAGE_AMD}")
if [[ -n "$IMAGE_ARM" ]]; then
  TARGETS+=("VM.Standard.A1.Flex|1|1|${IMAGE_ARM}")
  TARGETS+=("VM.Standard.A1.Flex|1|6|${IMAGE_ARM}")
  TARGETS+=("VM.Standard.A1.Flex|2|12|${IMAGE_ARM}")
fi
[[ ${#TARGETS[@]} -gt 0 ]] || { log "Ни одного образа не нашлось — ловить нечем"; exit 1; }
log "Формы в очереди: ${#TARGETS[@]} — $(printf '%s ' "${TARGETS[@]%%|*}")"

METADATA=$(jq -nc --arg k "$SSH_PUBKEY" '{ssh_authorized_keys:$k}')

attempt=0
round=0
throttle=0
capacity_misses=0

while ! expired; do
  round=$(( round + 1 ))

  for ad in "${ADS[@]}"; do
    expired && break
    for target in "${TARGETS[@]}"; do
      expired && break
      IFS='|' read -r shape ocpus ram image <<< "$target"
      attempt=$(( attempt + 1 ))

      args=(
        --availability-domain "$ad"
        --compartment-id "$OCI_COMPARTMENT_ID"
        --shape "$shape"
        --subnet-id "$OCI_SUBNET_ID"
        --assign-public-ip true
        --image-id "$image"
        --boot-volume-size-in-gbs "$BOOT_GB"
        --display-name "$INSTANCE_NAME"
        --metadata "$METADATA"
        --wait-for-state RUNNING
      )
      # E2.1.Micro — фиксированная форма, shape-config ей передавать нельзя.
      if [[ "$shape" == *.Flex ]]; then
        args+=(--shape-config "{\"ocpus\":${ocpus},\"memoryInGBs\":${ram}}")
      fi

      set +e
      out=$(oci compute instance launch "${args[@]}" 2>&1)
      rc=$?
      set -e

      if [[ $rc -eq 0 ]]; then
        ip=$(jq -r '.data."public-ip" // empty' <<<"$out" 2>/dev/null || true)
        [[ -n "$ip" ]] || ip="(смотри в консоли)"
        size="${ocpus} OCPU / ${ram} GB"
        [[ "$shape" == *.Flex ]] || size="1 OCPU / 1 GB"
        notify "🎉 Oracle: поймал ${shape} (${size}) в ${ad}. IP: ${ip}. Попыток в этом прогоне: ${attempt}."
        log "$out"
        exit 0
      fi

      if grep -qiE 'Out of (host )?capacity' <<< "$out"; then
        capacity_misses=$(( capacity_misses + 1 ))
        # Дошли до планировщика — значит нас не душат, отпускаем тормоз.
        (( throttle > 0 )) && throttle=$(( throttle - 1 ))
      elif grep -qiE '"code": *"TooManyRequests"|"status": *429' <<< "$out"; then
        throttle=$(( throttle + 1 ))
        backoff=$(( 60 * throttle ))
        (( backoff > 600 )) && backoff=600
        log "Rate limit (уровень ${throttle}) — пауза ${backoff} с"
        sleep "$backoff"
        continue
      elif grep -qiE 'LimitExceeded|QuotaExceeded' <<< "$out"; then
        notify "⛔ Oracle: квота Always Free исчерпана. Ловля остановлена."
        exit 1
      elif grep -qiE 'NotAuthenticated|NotAuthorizedOrNotFound' <<< "$out"; then
        notify "⛔ Oracle: ошибка доступа у пользователя catcher. Проверь ключ, fingerprint и политику."
        log "$out"
        exit 1
      else
        log "Неожиданная ошибка (${shape}/${ad}): $(head -c 400 <<< "$out")"
      fi

      sleep "$ATTEMPT_GAP"
    done
  done

  (( round % 20 == 0 )) && log "Круг ${round}: попыток ${attempt}, отказов по ёмкости ${capacity_misses}"
  sleep $(( ROUND_GAP_MIN + RANDOM % (ROUND_GAP_MAX - ROUND_GAP_MIN + 1) ))
done

log "Дедлайн прогона (${DEADLINE_MIN} мин). Попыток ${attempt}, отказов по ёмкости ${capacity_misses}, карантинов ${throttle}."
log "Следующий прогон запустит расписание."
exit 0
