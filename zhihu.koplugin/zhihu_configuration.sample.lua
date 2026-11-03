-- Documentation only. Configure from KOReader's 知乎 → 设置 menu.
-- Live settings are JSON in DataStorage:getSettingsDir()/zhihu_configuration.json.
return {
    base_url = "https://developer.zhihu.com",
    access_secret = "",
    hot_limit = 30, -- 1..30
    timeout = 30, -- 5..120 seconds, including the UI watchdog
    model = "zhida-fast-1p5",
    download_images = false, -- MVP text only; P1 will add image downloads
}
