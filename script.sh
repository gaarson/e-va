# 1. Удаляем старые модули, скомпилированные под 5.1
rm -rf lua_modules
mkdir -p lua_modules

# 2. Список пакетов (я убрал bit32, объяснение ниже)
PACKAGES="basexx binaryheap busted compat53 cqueues datafile dkjson fifo http inspect json-lua lpeg lpeg_patterns lua-cjson lua-term lua_cliargs luacov luafilesystem luaossl luassert luasystem mediator_lua penlight say"

# 3. Цикл установки
for pkg in $PACKAGES; do
    echo "========================================="
    echo "Устанавливаем: $pkg"
    echo "========================================="
    # Устанавливаем пакет. Если один упал, пишем ошибку и идем дальше
    luarocks --lua-version=5.4 install --tree lua_modules $pkg || echo "[ОШИБКА] Не удалось установить $pkg"
done

echo "Готово! Проверьте папку lua_modules."
