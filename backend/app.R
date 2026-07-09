
library(shiny)
library(bslib)
library(readr)
library(dplyr)
library(caret)
library(officer)  # для экспорта в Word
library(flextable)  # для таблиц в Word

# === Модель ===
mdl <- readRDS("rf_pd_model.rds")

FEATS <- c("Cap_gr","Cash_ratio","DCR","DTA","EBITDA_debt","IC","LR","Rev_gr","ROA","TA")
FEAT_LABELS <- c(
  Cap_gr      = "Рост капитала",
  Cash_ratio  = "Доля денежных средств",
  DCR         = "Покрытие долга",
  DTA         = "Долг / Активы",
  EBITDA_debt = "EBITDA / Долг",
  IC          = "Процентное покрытие",
  LR          = "Текущая ликвидность",
  Rev_gr      = "Рост выручки",
  ROA         = "Рентабельность активов",
  TA          = "Совокупные активы"
)

# ТЕКСТЫ ПОДСКАЗОК
TOOLTIPS <- c(
  Cap_gr      = "Темп прироста собственного капитала. Выше — устойчивее.",
  Cash_ratio  = "Доля денежных средств и эквивалентов. Характеризует мгновенную ликвидность.",
  DCR         = "Покрытие долга денежным потоком (Debt Coverage Ratio). Больше — безопаснее.",
  DTA         = "Долг/Активы. Рост коэффициента = рост долговой нагрузки.",
  EBITDA_debt = "EBITDA/Долг. Показывает способность обслуживать долг.",
  IC          = "Процентное покрытие (EBIT/проценты). < 1 — тревожный сигнал.",
  LR          = "Оборотные активы / краткосрочные обязательства. ≈2 — комфортный уровень.",
  Rev_gr      = "Годовой рост выручки. Отрицательное значение — риск.",
  ROA         = "Чистая прибыль / активы. Эффективность использования активов.",
  TA          = "Размер активов. Косвенно связан с устойчивостью."
)

ALIAS <- c(CRA = "Cash_ratio")

coeff_thresholds <- list(
  Cap_gr      = c(0.00, 0.05, 0.10),
  Cash_ratio  = c(0.10, 0.20, 0.30),
  DCR         = c(1.00, 1.50, 2.00),
  DTA         = c(0.50, 0.60, 0.70),
  EBITDA_debt = c(0.10, 0.20, 0.30),
  IC          = c(1.00, 2.00, 3.00),
  LR          = c(1.00, 1.20, 1.50),
  Rev_gr      = c(-0.10, 0.00, 0.10),
  ROA         = c(-0.05, 0.00, 0.05),
  TA          = c(0.50, 1.00, 2.00)
)

risk_stage <- function(pd) cut(pd, c(-Inf,.2,.6,Inf),
                               c("Стандартный риск","Повышенный риск","Высокий риск"))

preprocess <- function(df){
  df2 <- as.data.frame(df, stringsAsFactors = FALSE)
  for (f in FEATS){
    if (!f %in% names(df2)) df2[[f]] <- NA_real_
    df2[[f]] <- suppressWarnings(as.numeric(df2[[f]]))
  }
  df2[FEATS][is.na(df2[FEATS])] <- 0
  req_preds <- tryCatch(caret::predictors(mdl), error=function(e) NULL)
  if (is.null(req_preds) || !length(req_preds))
    if (!is.null(mdl$trainingData)) req_preds <- setdiff(colnames(mdl$trainingData), ".outcome")
  if (is.null(req_preds) || !length(req_preds)) req_preds <- FEATS
  
  X <- as.data.frame(setNames(as.list(rep(NA_real_, length(req_preds))), req_preds))
  common <- intersect(req_preds, names(df2))
  if (length(common))
    X[common] <- lapply(common, function(nm) suppressWarnings(as.numeric(df2[[nm]])))
  
  if (length(ALIAS))
    for (nm in names(ALIAS)){
      src <- ALIAS[[nm]]
      if (nm %in% req_preds && src %in% names(df2))
        X[[nm]] <- suppressWarnings(as.numeric(df2[[src]]))
    }
  
  for (nm in req_preds){
    if (!is.numeric(X[[nm]])) X[[nm]] <- suppressWarnings(as.numeric(X[[nm]]))
    X[[nm]][is.na(X[[nm]])] <- 0
  }
  X
}

pick_bad_prob <- function(probs){
  if ("bad" %in% colnames(probs)) return(probs[,"bad"])
  if (!is.null(mdl$levels)){
    lbl <- if ("bad" %in% mdl$levels) "bad" else tail(mdl$levels,1)
    if (lbl %in% colnames(probs)) return(probs[,lbl])
  }
  if (ncol(probs) >= 2) return(probs[,2]) else return(probs[,1])
}

marker_pos <- function(val, thr){
  seg <- 1/4
  if (is.na(val)) return(0)
  if (val < thr[1]) return(seg * (val / max(thr[1], 1e-9)))
  if (val < thr[2]) return(seg*1 + seg*((val-thr[1]) / max(thr[2]-thr[1],1e-9)))
  if (val < thr[3]) return(seg*2 + seg*((val-thr[2]) / max(thr[3]-thr[2],1e-9)))
  seg*3 + seg*0.9
}

ui <- fluidPage(
  theme = bslib::bs_theme(
    version = 5,
    primary = "#4f46e5",
    base_font = "system-ui, -apple-system, 'Segoe UI', Roboto, Helvetica, Arial, 'Noto Sans', 'Liberation Sans', 'DejaVu Sans', sans-serif",
    heading_font = "inherit"
  ),
  
  # JS: инициализация Bootstrap tooltips
  tags$script(HTML("
    function initTips(){
      var els = [].slice.call(document.querySelectorAll('[data-bs-toggle=\"tooltip\"]'));
      els.forEach(function(el){
        if(!bootstrap.Tooltip.getInstance(el)){ new bootstrap.Tooltip(el); }
      });
    }
    document.addEventListener('DOMContentLoaded', initTips);
    Shiny.addCustomMessageHandler('reinitTips', function(x){ setTimeout(initTips, 50); });
    Shiny.addCustomMessageHandler('markInvalid', function(ids){
      ids.forEach(function(id){var el=document.getElementById(id); if(el){el.classList.add('invalid-input');}});
    });
    Shiny.addCustomMessageHandler('clearInvalid', function(ids){
      ids.forEach(function(id){var el=document.getElementById(id); if(el){el.classList.remove('invalid-input');}});
    });
    Shiny.addCustomMessageHandler('copyResults', function(text) {
      navigator.clipboard.writeText(text).then(function() {
        Shiny.setInputValue('copySuccess', true);
      }).catch(function(err) {
        console.error('Failed to copy: ', err);
      });
    });
    Shiny.addCustomMessageHandler('goLogout', function(){
      window.location.href = '/rai/logout';
    });
  ")),
  
  # Стили
  tags$style(HTML(
    "body{background-color:#f9fafb;
          color:#111827; 
          display:flex; 
          justify-content:center;
          font-family: 'Inter', sans-serif;
          min-height: 100vh;
          padding: 0;
          margin: 0;}
     .main-container{display: flex; width: 100%; max-width: 1400px; margin: 20px auto; gap: 20px;}
     .sidebar{width: 300px; background: #ffffff; 
              border-radius: 12px; 
              padding: 20px; 
              box-shadow: 0 4px 6px -1px rgba(0,0,0,0.1), 0 2px 4px -1px rgba(0,0,0,0.06);
              height: fit-content;
              position: sticky;
              top: 20px;}
     .content{flex: 1; min-width: 0;}
     .panel{background:#ffffff;
            border-radius:12px;
            padding:20px;
            box-shadow: 0 4px 6px -1px rgba(0,0,0,0.1), 0 2px 4px -1px rgba(0,0,0,0.06);}
     .inputs{display:grid;grid-template-columns:repeat(5,minmax(180px,1fr));gap:12px;}
     .form-control{background:#f9fafb!important;
                   color:#111827!important;
                   border: 1px solid #d1d5db !important;
                   border-radius: 6px !important;
                   padding: 8px 12px !important;
                   transition: all 0.2s;}
     .form-control:focus{border-color:#4f46e5 !important; 
                         box-shadow: 0 0 0 3px rgba(79, 70, 229, 0.1) !important;}
     .btn-accent{background:#4f46e5!important;
                 border-color:#4f46e5!important;
                 color:#ffffff!important;
                 font-weight:700;
                 border-radius: 6px !important;
                 padding: 8px 16px !important;
                 margin: 5px 0 !important;
                 display: block;
                 width: 100%;}
     .btn-accent:hover{background:#4338ca!important;
                       border-color:#4338ca!important;}
     .btn-secondary{background:#e5e7eb!important;
                    border-color:#e5e7eb!important;
                    color:#374151!important;
                    font-weight:500;
                    border-radius: 6px !important;
                    padding: 8px 16px !important;
                    margin: 5px 0 !important;
                    display: block;
                    width: 100%;}
     .btn-secondary:hover{background:#d1d5db!important;
                          border-color:#d1d5db!important;}
     .btn-export{background:#10b981!important;
                 border-color:#10b981!important;
                 color:#ffffff!important;
                 font-weight:500;
                 border-radius: 6px !important;
                 padding: 8px 16px !important;
                 margin: 5px 0 !important;
                 display: block;
                 width: 100%;}
     .btn-export:hover{background:#059669!important;
                       border-color:#059669!important;}
     .btn-copy{background:#6366f1!important;
               border-color:#6366f1!important;
               color:#ffffff!important;
               font-weight:500;
               border-radius: 6px !important;
               padding: 8px 16px !important;
               margin: 5px 0 !important;
               display: block;
               width: 100%;}
     .btn-copy:hover{background:#4f46e5!important;
                     border-color:#4f46e5!important;}
     .panel label{color:#374151!important;
                  font-weight:600;
                  margin-bottom: 4px !important;
                  display: block;}
     .title{color:#4f46e5!important;
            font-weight:800;
            margin-bottom: 12px !important;
            font-size:28px;
            text-decoration:underline;
            letter-spacing:.3px;
            text-align: center;
            margin-top: 0;
            margin-bottom: 20px;}
     .section{color:#4f46e5!important;
              font-weight:800;
              margin-bottom: 12px !important;}
     .warn{color:#dc2626;
           font-weight:600;
           background-color: #fef2f2;
           padding: 8px 12px;
           border-radius: 6px;
           display: inline-block;
           margin-top: 10px;
           width: 100%;}
     .invalid-input{border:2px solid #dc2626!important;
                    box-shadow:0 0 6px rgba(220, 38, 38, 0.35)!important;
                    background-color: #fef2f2 !important;}
     .orig{display:block;
           font-size:12px;
           opacity:.7;
           color:#6b7280;
           margin-top:2px;}
     .tip{display:inline-block;
          font-size:13px;
          cursor:pointer;
          color:#6b7280;
          opacity:0.85;
          margin-left: 4px;
          text-decoration: underline;
          text-decoration-style: dotted;}
     .tip-block{display:inline-block;
                margin-left: 4px;
                vertical-align: top;}
     .glass{background:#ffffff;
            border:1px solid #e5e7eb;
            box-shadow:0 1px 3px 0 rgba(0,0,0,0.05);
            border-radius:8px;
            padding:16px;
            margin-top:10px;
            border-radius: 8px;}
     .scale-row{display:flex;
                align-items:center;
                gap:12px;
                margin:12px 0;
                padding: 8px 0;}
     .scale-label{min-width:280px;
                  font-weight:700;
                  color:#374151;
                  line-height: 1.4;}
     .scale{position:relative;
            display:grid;
            grid-template-columns:repeat(4,1fr);
            width:720px;
            height:16px;
            border-radius:8px;
            overflow:hidden;
            box-shadow:inset 0 0 0 1px rgba(0,0,0,.08);}
     .seg1{background:#10b981}  /* Зеленый */
     .seg2{background:#f59e0b}  /* Желтый */
     .seg3{background:#f97316}  /* Оранжевый */
     .seg4{background:#ef4444}  /* Красный */
     .marker{position:absolute;
             top:50%;
             transform:translate(-50%,-50%);
             font-size:14px;
             color:#ffffff;
             font-weight: bold;
             background-color: #374151;
             width: 24px;
             height: 24px;
             border-radius: 50%;
             display: flex;
             align-items: center;
             justify-content: center;
             z-index: 10;
             box-shadow: 0 2px 4px rgba(0,0,0,0.2);}
     .marker::before{content:'●';}
     .risk-pill{display:inline-block;
                padding:6px 12px;
                border-radius:999px;
                font-weight:700;
                font-size: 14px;
                min-width: 150px;
                text-align: center;}
     .risk-green{background:#d1fae5;
                 color:#065f46;}
     .risk-amber{background:#fef3c7;
                 color:#d97706;}
     .risk-red{background:#fecaca;
               color:#b91c1c;}
     .section{font-size: 1.25rem;
              margin-top: 24px;
              margin-bottom: 16px;
              padding-bottom: 8px;
              border-bottom: 2px solid #e5e7eb;}
     .sidebar-title{color: #4f46e5; font-weight: 700; margin-bottom: 16px; font-size: 1.2rem;}
     .sidebar-section{margin-bottom: 20px; padding-bottom: 15px; border-bottom: 1px solid #e5e7eb;}
     .sidebar-section:last-child{border-bottom: none; margin-bottom: 0; padding-bottom: 0;}
     .sidebar-item{margin: 8px 0;}
     .info-text{font-size: 14px; color: #6b7280; line-height: 1.5; margin-bottom: 12px;}
     .legend-item{display: flex; align-items: center; margin: 8px 0;}
     .legend-color{width: 20px; height: 20px; border-radius: 4px; margin-right: 10px;}
     .legend-text{font-size: 14px; color: #374151;}
     .org-name{font-size: 28px; font-weight: 700; color: #4f46e5; text-decoration: underline; margin-bottom: 16px; letter-spacing:.3px; text-align: center;}
     .risk-result-card{background: linear-gradient(135deg, #f0f9ff 0%, #e0f2fe 100%);
                      border-radius: 12px;
                      padding: 20px;
                      text-align: center;
                      margin: 15px 0;
                      box-shadow: 0 4px 6px -1px rgba(0,0,0,0.1);}
     .risk-value{font-size: 2.5rem;
                 font-weight: 800;
                 color: #4f46e5;
                 margin: 10px 0;}
     .risk-label{font-size: 1.5rem;
                 font-weight: 700;
                 margin-bottom: 10px;}
     .risk-desc{font-size: 1rem;
                color: #6b7280;
                margin-bottom: 15px;}
     .risk-gauge{height: 20px;
                 background: linear-gradient(to right, #10b981, #f59e0b, #f97316, #ef4444);
                 border-radius: 10px;
                 margin: 15px 0;
                 position: relative;}
     .risk-pointer{position: absolute;
                   top: -5px;
                   width: 30px;
                   height: 30px;
                   background: #1f2937;
                   border-radius: 50%;
                   transform: translateX(-50%);
                   display: flex;
                   align-items: center;
                   justify-content: center;
                   color: white;
                   font-size: 12px;
                   font-weight: bold;
                   box-shadow: 0 2px 4px rgba(0,0,0,0.3);}
      .btn-logout{
        background:#ef4444!important;   /* красная */
        border-color:#ef4444!important;
        color:#ffffff!important;
        font-weight:700;
        border-radius: 6px !important;
        padding: 8px 16px !important;
        margin: 5px 0 !important;
        display:block;
        width:100%;
      }
      .btn-logout:hover{
        background:#dc2626!important;
        border-color:#dc2626!important;
      } 
                  "
  )),
  
  div(class="main-container",
      div(class="sidebar",
          div(class="org-name", "AFR"),
          div(class="sidebar-title", "Функции"),
          div(class="sidebar-section",
              div(class="sidebar-item", actionButton("reset", "Сбросить значения", class="btn-secondary")),
              div(class="sidebar-item", actionButton("load_sample", "Загрузить пример", class="btn-secondary")),
              div(class="sidebar-item", downloadButton("export", "Экспорт результатов", class="btn-export")),
              div(class="sidebar-item", actionButton("copy_results", "Копировать результаты", class="btn-copy")),
              tags$script(HTML("
                async function tryShowAnalytics(){
                  try{
                    const resp = await fetch('/auth/rai/whoami', {
                      credentials: 'include',
                      redirect: 'manual'
                    });
                    if (resp.status !== 200) return;                 // не залогинен/нет доступа
                    const ct = resp.headers.get('content-type') || '';
                    if (!ct.includes('application/json')) return;    // подстраховка
                    const data = await resp.json();

                    // показываем кнопку ТОЛЬКО если сервер сказал можно
                    if (!data.can_analytics) return;

                    const slot = document.getElementById('analytics-slot');
                    if (slot && !slot.dataset.filled){
                      slot.dataset.filled = '1';
                      const a = document.createElement('a');
                      a.href = '/rai/analytics';
                      a.className = 'btn-accent';
                      a.textContent = 'Аналитика';
                      a.style.background = '#0ea5e9';
                      a.style.borderColor = '#0ea5e9';
                      a.style.textAlign = 'center';
                      slot.appendChild(a);
                    }
                  }catch(e){
                    // console.error('whoami failed', e);
                  }
                }

                document.addEventListener('DOMContentLoaded', function(){
                  tryShowAnalytics();
                  setTimeout(tryShowAnalytics, 1000);
                  setTimeout(tryShowAnalytics, 3000);
                });
              ")), 

              div(class="sidebar-section",
                # сюда динамически вставим кнопку "Аналитика"
                div(id="analytics-slot")
              ),
              div(class="sidebar-item",
                tags$a(
                  href = "/rai/logout",
                  class = "btn-logout",
                  "Выйти"
                )
              )
          ),
          div(class="sidebar-section",
              div(class="sidebar-title", "Описание"),
              div(class="info-text", "R-AI - система оценки кредитного риска на основе машинного обучения."),
              div(class="info-text", "Введите значения финансовых коэффициентов для получения вероятности дефолта."),
              div(class="info-text", "Цветные шкалы показывают диапазоны риска для каждого коэффициента.")
          ),
          div(class="sidebar-section",
              div(class="sidebar-title", "Легенда риска"),
              div(class="legend-item",
                  div(class="legend-color", style="background-color: #d1fae5;"),
                  div(class="legend-text", "Стандартный риск")
              ),
              div(class="legend-item",
                  div(class="legend-color", style="background-color: #fef3c7;"),
                  div(class="legend-text", "Повышенный риск")
              ),
              div(class="legend-item",
                  div(class="legend-color", style="background-color: #fecaca;"),
                  div(class="legend-text", "Высокий риск")
              )
          )
      ),
      div(class="content",
          div(class="title", "R-AI"),
          div(class="panel",
              div(class="inputs",
                  lapply(FEATS, function(f){
                    # 1-я строка — полное название
                    # 2-я строка — аббревиатура
                    # 3-я строка — иконка подсказки (отдельной строкой)
                    lbl <- sprintf(
                      "%s<br><span class='orig'>(%s)</span>",
                      FEAT_LABELS[[f]], f
                    )
                    numericInput(
                      inputId = paste0("in_", f),
                      label   = HTML(lbl),
                      value   = NA,
                      step    = 0.01
                    )
                  })
              ),
              div(style="margin-top:16px;", 
                  actionButton("calc","Рассчитать риск", class="btn-accent"),
                  span(class="tip tip-block", 
                       style="margin-left: 12px;",
                       "ℹ️", 
                       "data-bs-toggle"="tooltip", 
                       title="Заполните все поля и нажмите кнопку для расчета вероятности дефолта")
              )
          ),
          h4("Результат", class="section", style="margin-top:16px;"),
          div(class="risk-result-card",
              uiOutput("res")
          ),
          h4("Коэффициенты", class="section", style="margin-top:16px;"),
          div(class="glass", uiOutput("scales"))
      )
  )
)

server <- function(input, output, session){
  
  # Reactive values для хранения результатов
  results <- reactiveValues(pd = NULL, risk_stage = NULL, inputs = NULL, scales = NULL)
  
  highlight_missing <- function(vals){
    na_ids <- paste0("in_", FEATS[is.na(vals)])
    ok_ids <- paste0("in_", FEATS[!is.na(vals)])
    if (length(na_ids)) session$sendCustomMessage('markInvalid', na_ids)
    if (length(ok_ids)) session$sendCustomMessage('clearInvalid', ok_ids)
  }
  
  marker_pos <- function(val, thr){
    seg <- 1/4
    if (is.na(val)) return(0)
    if (val < thr[1]) return(seg * (val / max(thr[1], 1e-9)))
    if (val < thr[2]) return(seg*1 + seg*((val-thr[1]) / max(thr[2]-thr[1],1e-9)))
    if (val < thr[3]) return(seg*2 + seg*((val-thr[2]) / max(thr[3]-thr[2],1e-9)))
    seg*3 + seg*0.9
  }
  
  observeEvent(input$calc, {
    vals <- vapply(FEATS, function(f) input[[paste0("in_",f)]], numeric(1))
    if (any(is.na(vals))){
      highlight_missing(vals)
      output$res <- renderUI(
        div(class="warn", "⚠️ Заполните все поля перед расчётом")
      )
      output$scales <- renderUI(NULL)
      results$pd <- NULL
      results$risk_stage <- NULL
      results$inputs <- NULL
      results$scales <- NULL
      return()
    } else {
      # Очищаем выделение полей
      highlight_missing(rep(0,length(vals)))
    }
    
    new1 <- as.data.frame(t(vals)); names(new1) <- FEATS
    X <- preprocess(new1)
    probs <- predict(mdl, newdata = X, type = 'prob'); pd <- pick_bad_prob(probs)
    
    st  <- as.character(risk_stage(pd))
    cls <- if (pd<.2) "risk-pill risk-green" else if (pd<.6) "risk-pill risk-amber" else "risk-pill risk-red"
    
    # Расчет позиции указателя для градиента риска (0-100%)
    risk_pos <- min(100, max(0, pd * 100))
    
    output$res <- renderUI(
      tagList(
        div(class="risk-label", "Уровень риска"),
        div(class="risk-value", paste0(round(pd * 100, 2), "%")),
        div(class="risk-desc", paste("Вероятность дефолта:", st)),
        div(class="risk-gauge",
            div(class="risk-pointer", style=paste0("left:", risk_pos, "%;"), "●")
        ),
        div(span("Интерпретация: ", class="risk-desc"), span(st, class=cls))
      )
    )
    
    # Сохраняем шкалы для копирования
    scales_ui <- tagList(lapply(seq_along(FEATS), function(i){
      f <- FEATS[i]; val <- vals[i]; thr <- coeff_thresholds[[f]]
      pos <- marker_pos(val, thr)
      div(class='scale-row',
          div(class='scale-label',
              HTML(sprintf("%s<br><span class='orig'>(%s)</span>",
                           FEAT_LABELS[[f]], f))
          ),
          div(class='scale',
              div(class='seg1'), div(class='seg2'), div(class='seg3'), div(class='seg4'),
              div(class='marker', style=paste0('left:', sprintf('%.1f', pos*100), '%'))
          ),
          span(class="tip", 
               "ℹ️", 
               "data-bs-toggle"="tooltip", 
               title=TOOLTIPS[[f]])
      )
    }))
    
    output$scales <- renderUI(scales_ui)
    
    # Сохраняем результаты для экспорта и копирования
    results$pd <- pd
    results$risk_stage <- st
    results$inputs <- vals
    results$scales <- scales_ui
    
    session$sendCustomMessage('reinitTips', TRUE)
  })
  
  # Сброс значений
  observeEvent(input$reset, {
    for(f in FEATS) {
      updateNumericInput(session, paste0("in_", f), value = NA)
    }
    output$res <- renderUI(NULL)
    output$scales <- renderUI(NULL)
    results$pd <- NULL
    results$risk_stage <- NULL
    results$inputs <- NULL
    results$scales <- NULL
  })
  
  # Загрузка примера
  observeEvent(input$load_sample, {
    # Примерные значения для демонстрации
    example_values <- list(
      Cap_gr = 0.08,
      Cash_ratio = 0.15,
      DCR = 1.8,
      DTA = 0.45,
      EBITDA_debt = 0.25,
      IC = 2.5,
      LR = 1.4,
      Rev_gr = 0.05,
      ROA = 0.03,
      TA = 1.2
    )
    
    for(f in FEATS) {
      updateNumericInput(session, paste0("in_", f), value = example_values[[f]])
    }
  })
  
  observeEvent(input$logout, {
    # Передаём сигнал в JS, он выполнит redirect на /logout
    session$sendCustomMessage('goLogout', TRUE)
  })

  # Копирование результатов (включая шкалы)
  observeEvent(input$copy_results, {
    if (!is.null(results$pd)) {
      # Формируем текст с результатами
      result_text <- paste(
        "=== Результаты анализа R-AI ===",
        paste("Вероятность дефолта:", round(results$pd, 4)),
        paste("Уровень риска:", results$risk_stage),
        "",
        "=== Введенные значения ===",
        paste(sapply(seq_along(FEATS), function(i) {
          paste(FEAT_LABELS[[i]], ":", round(results$inputs[i], 4))
        }), collapse = "\n"),
        "",
        "=== Шкалы риска ===",
        paste(sapply(seq_along(FEATS), function(i) {
          f <- FEATS[i]
          val <- results$inputs[i]
          pos <- marker_pos(val, coeff_thresholds[[f]])
          # Определяем цветовую зону
          if (is.na(val)) zone <- "Не заполнено"
          else if (val < coeff_thresholds[[f]][1]) zone <- "Зеленая зона"
          else if (val < coeff_thresholds[[f]][2]) zone <- "Желтая зона"
          else if (val < coeff_thresholds[[f]][3]) zone <- "Оранжевая зона"
          else zone <- "Красная зона"
          
          paste(FEAT_LABELS[[i]], ":", round(val, 4), "(", zone, ")")
        }), collapse = "\n"),
        sep = "\n"
      )
      session$sendCustomMessage('copyResults', result_text)
      showNotification("Результаты (включая шкалы) скопированы в буфер обмена", type = "default")
    } else {
      showNotification("Нет результатов для копирования. Сначала выполните расчет.", type = "warning")
    }
  })
  
  # Обработка успешного копирования
  observeEvent(input$copySuccess, {
    if (input$copySuccess) {
      showNotification("Текст скопирован в буфер обмена", type = "message")
    }
  })
  
  # Экспорт в Word
  output$export <- downloadHandler(
    filename = function() {
      paste("R-AI_результаты_", Sys.Date(), ".docx", sep = "")
    },
    content = function(file) {
      doc <- read_docx()

      # Заголовок: используем стили, которые точно есть (регистр важен!)
      doc <- doc |>
        body_add_par("Отчёт R-AI", style = "heading 1") |>
        body_add_par(paste("Дата:", Sys.Date()), style = "heading 2")

      if (!is.null(results$pd)) {
        # Блок результатов
        doc <- doc |>
          body_add_par("Результаты анализа", style = "heading 2") |>
          body_add_par(paste("Вероятность дефолта:", round(results$pd, 4)), style = "Normal") |>
          body_add_par(paste("Уровень риска:", results$risk_stage), style = "Normal")

        # Таблица "Введённые значения" через flextable
        input_data <- data.frame(
          Показатель = FEAT_LABELS,
          Значение   = round(results$inputs, 4),
          check.names = FALSE,
          stringsAsFactors = FALSE
        )

        ft_inputs <- flextable::flextable(input_data)
        ft_inputs <- flextable::autofit(ft_inputs)

        doc <- doc |>
          body_add_par("Введённые значения", style = "heading 3") |>
          flextable::body_add_flextable(value = ft_inputs)

        # Таблица "Шкалы риска"
        scales_data <- data.frame(
          Показатель = FEAT_LABELS,
          Значение   = round(results$inputs, 4),
          Зона       = sapply(seq_along(FEATS), function(i) {
            val <- results$inputs[i]
            thr <- coeff_thresholds[[FEATS[i]]]
            if (is.na(val)) "Не заполнено"
            else if (val < thr[1]) "Зелёная (безопасная)"
            else if (val < thr[2]) "Жёлтая (умеренная)"
            else if (val < thr[3]) "Оранжевая (высокая)"
            else "Красная (очень высокая)"
          }),
          check.names = FALSE,
          stringsAsFactors = FALSE
        )

        ft_scales <- flextable::flextable(scales_data)
        ft_scales <- flextable::autofit(ft_scales)

        doc <- doc |>
          body_add_par("Шкалы риска", style = "heading 3") |>
          flextable::body_add_flextable(value = ft_scales)

      } else {
        doc <- doc |>
          body_add_par("Результаты анализа", style = "heading 2") |>
          body_add_par("Данные для анализа отсутствуют. Пожалуйста, выполните расчёт.", style = "Normal")
      }

      print(doc, target = file)
    },
    contentType = "application/vnd.openxmlformats-officedocument.wordprocessingml.document"
  )
}

shinyApp(ui, server)