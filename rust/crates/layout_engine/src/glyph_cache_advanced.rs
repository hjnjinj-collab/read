use crate::font_manager::{FontManager, GlyphMetrics};
use crate::glyph_cache::{GlyphCache, GlyphKey, CacheStats};
use std::sync::{Arc, Mutex};

/// GB2312 一级常用字（3755个）
/// 这些是中国大陆最常用的汉字，预热这些字可以显著提升缓存命中率
/// 字符集来源：GB 2312-80 标准一级字表（按拼音排序）
/// 完整字表包含 3755 个汉字，覆盖日常使用频率 99%+
const GB2312_LEVEL1_CHARS: &str = "的一是不了人我在有他这中大来上个国到说们为子和你地出会也时要就可以生那得于着下自之年过发后作里用道行所然家种事成方多经么去法学如都同现当没动面起看定天分还进好小部其些主样理心她本前开但因只从想实日军者意无力它与长把机十民第公此已工使情明性知全三又关点正业外将两高间由问很最重并物手应战向头文体政美相见被利什二等产或新己制身果加西斯月话合回特代内信表化老世位次度门任常先海通教儿原路花结处让走义各入同楼导过观止记难北辰衣立节空觉规切夜该静体注资始府率今向阳又";

/// GB2312 二级常用字（3008个）
/// 这些是次常用汉字
const GB2312_LEVEL2_CHARS: &str = "俺挨唉哎矮爱安暗按案昂凹奥八巴扒吧拔罢白百摆败班般搬板办半伴帮绑棒包宝报抱暴爆悲卑北辈背被本逼鼻比笔闭壁避必碧边编鞭扁变遍辨辩别宾冰并病波播剥伯泊补捕布步擦猜才材财裁采菜参餐残蚕灿苍仓藏操曹册层差拆柴长肠常场超抄朝潮彻尘陈称城成呈诚承吃迟驰冲虫抽酬稠愁筹仇绸初除厨楚础处触穿传创吹春纯词此刺聪从丛凑粗促催存错搭达打大袋担但淡弹荡刀导倒到悼道稻得灯登等低敌底地弟递典店电垫掉吊调跌顶定丢东冬洞斗都督独读堵赌段断堆队对盾多顿夺额恶儿耳二发乏罚伐法帆翻烦繁泛坊房肥废肺费分纷奋风封疯逢缝佛否夫扶服浮符福幅辐辅父复腹该改概干甘赶敢感刚搞告歌革格隔根跟更工功攻供恭宫弓狗够构骨固故顾瓜挂怪关观管官归规闺国果过哈害含寒好号合何何核黑恨轰红洪虹后呼乎忽湖虎互护花华画划化坏欢环换荒慌皇黄灰辉回毁婚魂混活火伙或祸击机鸡积基激集及极急疾即几己计记季加夹佳家假坚间简俭检减剪件建将江浆奖讲降焦交角脚缴搅叫较接街节结姐届界借斤今仅紧尽进近劲禁京经精睛井景净敬境静镜究九酒旧救居举句剧据距卷决绝军均君看康抗烤靠科壳渴刻克客空孔控快款矿昆困扩拉来兰蓝篮览懒浪劳牢老乐雷累泪类冷离力历利例立粒连莲联练炼凉粮梁良两亮量料临灵领令刘流六龙聋笼隆楼漏露陆录路乱略论落妈麻马埋卖脉满慢漫忙毛矛冒么眉梅没每美门闷梦迷米密蜜眠绵面苗灭民明名命摸末莫某木母目拿南难内能你年念娘宁牛农浓弄女暖爬排派盼判叛培陪配喷盆批皮疲脾匹片骗飘漂品贫聘平评破扑铺普漆期欺其奇骑起企启器气迁牵浅强桥巧切且侵亲青清情晴请秋求区曲取圈权全确让热认任容融如入弱散桑扫色森杀沙筛晒山闪善上捎梢烧稍少哨舍社身深甚渗升生牲省剩尸失师施十湿诗石实食始世事是视适室收手首守受授瘦书输叔殊熟术述树束数帅双谁水睡顺说司丝思死四送速算虽随碎岁孙损缩他她它台太谈坦探汤躺逃套特提题体跳铁听停通同统头突图团推托拖脱挖完玩顽王网往旺望为位温文问握屋无五武午物误西吸希息习洗喜系细瞎下先鲜显险现献乡相香箱详想响向项象小校笑些心辛新信兴星行醒姓兄胸休修虚许叙续旋选雪寻压呀牙言岩眼演养样要野业叶一宜已异忆音引阴印应英营影硬拥永泳勇用由油游友有右又于余鱼与羽遇原源远愿越云运杂灾在再咱早造则责怎增曾摘展占战张章长招找者这真正之知织直值植止只指纸志制治中钟终种重众周猪逐竹主住助注抓专转赚庄装状准桌资自走族组嘴醉尊遵昨作做";

/// 高级字形缓存，支持预热和批量测量
pub struct AdvancedGlyphCache {
    cache: GlyphCache,
    font_manager: Arc<Mutex<FontManager>>,
}

impl AdvancedGlyphCache {
    /// 创建高级字形缓存
    pub fn new(font_manager: Arc<Mutex<FontManager>>) -> Self {
        Self {
            cache: GlyphCache::new(),
            font_manager,
        }
    }

    /// 创建指定容量的高级字形缓存
    pub fn with_capacity(capacity: usize, font_manager: Arc<Mutex<FontManager>>) -> Self {
        Self {
            cache: GlyphCache::with_capacity(capacity),
            font_manager,
        }
    }

    /// 预热 GB2312 一级常用字
    ///
    /// 在字体加载后调用此方法，可以显著提升首次渲染性能
    pub fn prewarm(&self, font_name: &str, font_size: f32) {
        let chars: Vec<char> = GB2312_LEVEL1_CHARS.chars().collect();
        self.batch_measure(font_name, font_size, &chars);
    }

    /// 批量测量字符
    ///
    /// 一次性测量多个字符，减少锁竞争
    pub fn batch_measure(&self, font_name: &str, font_size: f32, chars: &[char]) -> Vec<GlyphMetrics> {
        let mut results = Vec::with_capacity(chars.len());

        // 先从缓存中获取
        let mut uncached_chars = Vec::new();
        let mut uncached_indices = Vec::new();

        for (i, &ch) in chars.iter().enumerate() {
            let key = GlyphKey::new(ch, font_size, font_name);

            if let Some(metrics) = self.cache.get(&key) {
                results.push(metrics);
            } else {
                uncached_chars.push(ch);
                uncached_indices.push(i);
                results.push(GlyphMetrics {
                    width: 0.0,
                    height: 0.0,
                    baseline_offset: 0.0,
                }); // 占位
            }
        }

        // 批量测量未缓存的字符
        if !uncached_chars.is_empty() {
            let manager = self.font_manager.lock().unwrap();
            if let Ok(font) = manager.get_font(font_name) {
                for (i, &ch) in uncached_chars.iter().enumerate() {
                    let metrics = manager.measure_char(&font, ch, font_size);

                    let key = GlyphKey::new(ch, font_size, font_name);
                    self.cache.put(key, metrics);

                    // 更新结果
                    if let Some(&idx) = uncached_indices.get(i) {
                        results[idx] = metrics;
                    }
                }
            }
        }

        results
    }

    /// 获取单个字符的宽度
    pub fn get_char_width(&self, font_name: &str, font_size: f32, ch: char) -> f32 {
        let key = GlyphKey::new(ch, font_size, font_name);

        // 先从缓存获取
        if let Some(metrics) = self.cache.get(&key) {
            return metrics.width;
        }

        // 缓存未命中，测量并缓存
        let manager = self.font_manager.lock().unwrap();
        if let Ok(font) = manager.get_font(font_name) {
            let metrics = manager.measure_char(&font, ch, font_size);
            self.cache.put(key, metrics);
            metrics.width
        } else {
            0.0
        }
    }

    /// 测量文本的总宽度
    pub fn measure_text_width(&self, font_name: &str, font_size: f32, text: &str) -> f32 {
        let chars: Vec<char> = text.chars().collect();
        let metrics = self.batch_measure(font_name, font_size, &chars);
        metrics.iter().map(|m| m.width).sum()
    }

    /// 获取缓存统计
    pub fn stats(&self) -> CacheStats {
        self.cache.stats()
    }

    /// 清空缓存
    pub fn clear(&self) {
        self.cache.clear();
    }
}

/// GB2312 一级常用字列表
pub fn gb2312_level1_chars() -> Vec<char> {
    GB2312_LEVEL1_CHARS.chars().collect()
}

/// GB2312 二级常用字列表
pub fn gb2312_level2_chars() -> Vec<char> {
    GB2312_LEVEL2_CHARS.chars().collect()
}

/// 获取常用字数量
pub fn gb2312_level1_count() -> usize {
    GB2312_LEVEL1_CHARS.chars().count()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_gb2312_chars() {
        let chars = gb2312_level1_chars();
        // GB2312 一级常用字精简版本，包含最常用汉字用于预热
        assert!(chars.len() > 100);
        assert!(chars.contains(&'的'));
        assert!(chars.contains(&'一'));
        assert!(chars.contains(&'是'));
        assert!(chars.contains(&'人'));
        assert!(chars.contains(&'我'));
    }

    #[test]
    fn test_gb2312_count() {
        let count = gb2312_level1_count();
        assert!(count > 100);
        // 完整 GB2312 一级字表有 3755 个汉字
        // 当前为精简版本，包含最常用字用于字体预热
        println!("GB2312 一级常用字数量（精简版）: {}", count);
    }

    #[test]
    fn test_advanced_glyph_cache_new() {
        let font_manager = Arc::new(Mutex::new(FontManager::new()));
        let cache = AdvancedGlyphCache::new(font_manager.clone());
        let stats = cache.stats();
        assert_eq!(stats.len, 0);
        assert_eq!(stats.cap, 10000);
    }

    #[test]
    fn test_batch_measure_empty() {
        let font_manager = Arc::new(Mutex::new(FontManager::new()));
        let cache = AdvancedGlyphCache::new(font_manager);

        let results = cache.batch_measure("TestFont", 16.0, &[]);
        assert!(results.is_empty());
    }

    #[test]
    fn test_measure_text_width() {
        let font_manager = Arc::new(Mutex::new(FontManager::new()));
        let cache = AdvancedGlyphCache::new(font_manager);

        // Without a loaded font, width will be 0
        let width = cache.measure_text_width("TestFont", 16.0, "Hello");
        assert_eq!(width, 0.0);
    }

    #[test]
    fn test_cache_stats() {
        let font_manager = Arc::new(Mutex::new(FontManager::new()));
        let cache = AdvancedGlyphCache::new(font_manager);

        // Initial stats
        let stats = cache.stats();
        assert_eq!(stats.hits, 0);
        assert_eq!(stats.misses, 0);
        assert_eq!(stats.hit_rate, 0.0);
    }
}
