import Foundation

/// Published observations built into Storebench, so every model can price every covered country without a download. A live
/// download and the copy saved from it always come first; these are used only when neither can be read.
///
/// World Bank: PA.NUS.PPP (PPP conversion factor, GDP, local currency per international dollar) and PA.NUS.FCRF (official
/// exchange rate, local currency per US dollar), each country's newest year, licensed CC BY 4.0. The Economist: Big Mac
/// Index local prices, licensed CC BY 4.0.
enum BuiltInPricingIndexes {
    /// When each source last updated the data below.
    static let worldBankUpdated = "2026-11-11", bigMacUpdated = "2026-07-01"

    /// Country, year, P for PA.NUS.PPP or F for PA.NUS.FCRF, and the value.
    static let worldBankRows = """
        ABW,2024,P,1.3358003334369
        ABW,2024,F,1.79
        AFG,2024,P,13.2320571626481
        AGO,2025,P,322.965962233887
        AGO,2025,F,911.99303781631
        ALB,2025,P,39.9805375942293
        ALB,2025,F,86.8033333333333
        AND,2025,P,0.603848577368125
        AND,2025,F,0.887144250370587
        ARE,2024,P,2.32695589646038
        ARE,2024,F,3.6725
        ARG,2025,P,567.297421343424
        ARG,2025,F,1240.85125
        ARM,2025,P,148.11782018569
        ARM,2025,F,387.010152166483
        ATG,2025,P,1.87014584555665
        ATG,2025,F,2.7
        AUS,2025,P,1.398943
        AUS,2025,F,1.5519978866485
        AUT,2025,P,0.725357
        AUT,2025,F,0.88496895841236
        AZE,2025,P,0.482459128195909
        AZE,2025,F,1.7
        BDI,2025,P,999.612019047394
        BDI,2025,F,2943.1375
        BEL,2025,P,0.719942
        BEL,2025,F,0.88496895841236
        BEN,2025,P,200.336598367492
        BEN,2025,F,581.928481040339
        BFA,2025,P,217.410761840348
        BFA,2025,F,581.928481040339
        BGD,2025,P,30.9160155190794
        BGD,2025,F,121.920836605034
        BGR,2025,P,0.405704596599949
        BGR,2025,F,1.73519166666666
        BHR,2025,P,0.162039933977081
        BHR,2025,F,0.376
        BHS,2024,P,0.956315655509349
        BHS,2024,F,1.0
        BIH,2025,P,0.697646964731518
        BIH,2025,F,1.73592901689708
        BLR,2025,P,0.90876978092131
        BLR,2025,F,3.069175
        BLZ,2025,P,1.05113051635175
        BLZ,2025,F,2.0
        BMU,2024,P,1.19812062185577
        BMU,2024,F,1.0
        BOL,2025,P,2.76324583616839
        BOL,2025,F,6.91
        BRA,2025,P,2.55440835439356
        BRA,2025,F,5.58728623856661
        BRB,2025,P,2.19085217304192
        BRB,2025,F,2.0
        BRN,2025,P,0.456019597784343
        BRN,2025,F,1.307595108858
        BTN,2025,P,19.9848946493305
        BTN,2025,F,87.1584483507393
        BWA,2025,P,5.07409138676734
        BWA,2025,F,13.5023833333333
        CAF,2025,P,246.31590787299
        CAF,2025,F,581.928481040339
        CAN,2025,P,1.166683
        CAN,2025,F,1.39810565893901
        CHE,2025,P,0.930746
        CHE,2025,F,0.831355833333333
        CHL,2025,P,453.188563
        CHL,2025,F,951.329454191033
        CHN,2025,P,3.39768588417447
        CHN,2025,F,7.18984737402171
        CIV,2025,P,216.221332210196
        CIV,2025,F,581.928481040339
        CMR,2025,P,198.309241557697
        CMR,2025,F,581.928481040339
        COD,2025,P,1124.85430376458
        COD,2025,F,2693.24060103248
        COG,2025,P,201.890946598546
        COG,2025,F,581.928481040339
        COL,2025,P,1532.719303
        COL,2025,F,4053.13583333333
        COM,2025,P,211.662236779844
        COM,2025,F,435.376187289972
        CPV,2025,P,46.629436004152
        CPV,2025,F,97.8631517010164
        CRI,2025,P,297.351768
        CRI,2025,F,503.496832373272
        CUW,2024,P,1.24831756717631
        CUW,2024,F,1.79
        CYM,2024,P,0.94261799236714
        CYM,2024,F,0.83333
        CYP,2025,P,0.572620273384741
        CYP,2025,F,0.88496895841236
        CZE,2025,P,12.993503
        CZE,2025,F,21.882
        DEU,2025,P,0.709983
        DEU,2025,F,0.88496895841236
        DJI,2025,P,82.1238304290602
        DJI,2025,F,177.721
        DMA,2025,P,1.30631128267932
        DMA,2025,F,2.7
        DNK,2025,P,6.124666
        DNK,2025,F,6.62182508333333
        DOM,2025,P,23.8682512750234
        DOM,2025,F,61.9865666666666
        DZA,2025,P,42.8460510517715
        DZA,2025,F,131.605925
        ECU,2025,P,0.425220703426529
        ECU,2025,F,1.0
        EGY,2025,P,7.58370974796763
        EGY,2025,F,49.2277558333333
        ERI,2021,P,4.93847894668579
        ERI,2021,F,15.075
        ESP,2025,P,0.570991
        ESP,2025,F,0.88496895841236
        EST,2025,P,0.584555
        EST,2025,F,0.88496895841236
        ETH,2024,P,27.1045539967632
        ETH,2024,F,82.6013363504764
        ETH,2025,P,30.7650224136466
        FIN,2025,P,0.754195
        FIN,2025,F,0.88496895841236
        FJI,2025,P,0.934666867351328
        FJI,2025,F,2.29903333333333
        FRA,2025,P,0.677618
        FRA,2025,F,0.88496895841236
        FRO,2024,P,6.22980312304618
        FRO,2024,F,6.89448141666666
        FSM,2025,P,0.95865080658499
        FSM,2025,F,1.0
        GAB,2025,P,216.420044727798
        GAB,2025,F,581.928481040339
        GBR,2025,P,0.677133
        GBR,2025,F,0.759473957338607
        GEO,2025,P,0.903514180711349
        GEO,2025,F,2.74264166666666
        GHA,2025,P,4.75008975177416
        GHA,2025,F,12.556825
        GIN,2025,P,3286.09262410062
        GMB,2025,P,17.7935316169312
        GMB,2025,F,71.2893818242692
        GNB,2025,P,198.582744438309
        GNB,2025,F,581.928481040339
        GNQ,2025,P,238.615174467719
        GNQ,2025,F,581.928481040339
        GRC,2025,P,0.526872
        GRC,2025,F,0.88496895841236
        GRD,2025,P,1.53137011170231
        GRD,2025,F,2.7
        GRL,2023,P,5.10788380262313
        GRL,2023,F,6.88970258583334
        GTM,2025,P,3.33451157924276
        GTM,2025,F,7.68012458333333
        GUY,2025,P,69.0331367456556
        GUY,2025,F,208.5
        HKG,2025,P,5.52457295433365
        HKG,2025,F,7.79708333333333
        HND,2025,P,11.8640844280338
        HND,2025,F,25.9526748179551
        HRV,2025,P,0.470813052018898
        HRV,2025,F,0.88496895841236
        HTI,2025,P,112.359715746475
        HTI,2025,F,130.626409210526
        HUN,2025,P,183.57556
        HUN,2025,F,353.14
        IDN,2025,P,4720.99750025346
        IDN,2025,F,16477.8651797835
        IND,2025,P,20.0886288014602
        IND,2025,F,87.1584483507393
        IRL,2025,P,0.750891
        IRL,2025,F,0.88496895841236
        IRN,2023,P,94280.2670719049
        IRN,2023,F,42000.0
        IRN,2025,P,147937.809998602
        IRQ,2025,P,492.933552332882
        IRQ,2025,F,1300.0
        ISL,2025,P,151.367985
        ISL,2025,F,128.44148705495
        ISR,2025,P,3.487723
        ISR,2025,F,3.45189166666666
        ITA,2025,P,0.610275
        ITA,2025,F,0.88496895841236
        JAM,2025,P,95.7950373528488
        JAM,2025,F,159.096428305752
        JOR,2025,P,0.300588436411238
        JOR,2025,F,0.71
        JPN,2025,P,97.08005
        JPN,2025,F,149.657926890951
        KAZ,2025,P,172.827127700445
        KAZ,2025,F,521.035
        KEN,2025,P,43.5471478663385
        KEN,2025,F,129.302572099377
        KGZ,2025,P,29.1935664341276
        KGZ,2025,F,87.3598319399642
        KHM,2025,P,1349.49224235827
        KHM,2025,F,4013.43310400665
        KIR,2025,P,1.00874671689262
        KIR,2025,F,1.5519978866485
        KNA,2025,P,1.85174655680503
        KNA,2025,F,2.7
        KOR,2025,P,816.329274
        KOR,2025,F,1422.44083333333
        KWT,2025,P,0.175361574871678
        KWT,2025,F,0.306454776364577
        LAO,2025,P,4577.46196269632
        LAO,2025,F,20444.1366516587
        LBN,2024,P,33594.2483818204
        LBN,2024,F,89500.0
        LBR,2024,P,0.45443232675685
        LBR,2024,F,191.306666666666
        LBR,2025,P,0.462031881161655
        LBY,2025,P,2.07074496071786
        LBY,2025,F,5.30256666666666
        LCA,2025,P,1.38850270829587
        LCA,2025,F,2.7
        LKA,2025,P,88.2137716979226
        LKA,2025,F,300.851958333333
        LSO,2025,P,6.11792216885233
        LSO,2025,F,17.8887489855833
        LTU,2025,P,0.513169
        LTU,2025,F,0.88496895841236
        LUX,2025,P,0.832451
        LUX,2025,F,0.88496895841236
        LVA,2025,P,0.504702
        LVA,2025,F,0.88496895841236
        MAC,2025,P,4.44773830276597
        MAC,2025,F,8.02981025
        MAR,2025,P,3.93179684727296
        MAR,2025,F,9.35027697089946
        MDA,2025,P,7.48976511532315
        MDA,2025,F,17.3778474404761
        MDG,2025,P,1390.29172218468
        MDG,2025,F,4529.75125196404
        MDV,2025,P,7.88991987219358
        MDV,2025,F,15.415677547363
        MEX,2025,P,10.328951
        MEX,2025,F,19.2375083333333
        MHL,2025,P,0.946982695755452
        MHL,2025,F,1.0
        MKD,2025,P,20.453219828119
        MKD,2025,F,54.6549666666666
        MLI,2025,P,198.243965775836
        MLI,2025,F,581.928481040339
        MLT,2025,P,0.58711979275282
        MLT,2025,F,0.88496895841236
        MMR,2025,P,520.106449561224
        MNE,2025,P,0.370171163809184
        MNE,2025,F,0.887144250370587
        MNG,2025,P,1211.65358016366
        MNG,2025,F,3545.14356555046
        MOZ,2024,P,24.5764633742049
        MOZ,2024,F,63.905
        MOZ,2025,P,23.6620035302763
        MRT,2023,P,11.1785431496469
        MRT,2023,F,36.4891666666666
        MRT,2025,P,11.391685569891
        MUS,2025,P,17.7493221711606
        MUS,2025,F,45.9969666666666
        MWI,2023,P,401.327950703585
        MWI,2023,F,1161.09436666666
        MWI,2025,P,619.005548775964
        MYS,2025,P,1.35504364404393
        MYS,2025,F,4.28442415048243
        NAM,2025,P,7.27733758379859
        NAM,2025,F,17.8887333333333
        NER,2025,P,207.234045559658
        NER,2025,F,581.928481040339
        NGA,2025,P,195.022548515709
        NGA,2025,F,1518.38094813367
        NIC,2025,P,12.5185500987327
        NIC,2025,F,36.6243
        NLD,2025,P,0.746769
        NLD,2025,F,0.88496895841236
        NOR,2025,P,9.451661
        NOR,2025,F,10.3958333333333
        NPL,2025,P,33.8982001034302
        NPL,2025,F,139.115437592695
        NRU,2025,P,1.59287093272538
        NRU,2025,F,1.5519978866485
        NZL,2025,P,1.472957
        NZL,2025,F,1.72010833333333
        OMN,2025,P,0.181339214175172
        OMN,2025,F,0.3845
        PAK,2025,P,67.8368115155746
        PAK,2025,F,281.143001173202
        PAN,2025,P,0.45076892365416
        PAN,2025,F,1.0
        PER,2025,P,1.83592285276037
        PER,2025,F,3.56706380329909
        PHL,2025,P,19.069580238078
        PHL,2025,F,57.5050971489714
        PLW,2025,P,0.847328995677767
        PLW,2025,F,1.0
        PNG,2025,P,2.38719956855142
        PNG,2025,F,4.12272372720281
        POL,2025,P,1.969559
        POL,2025,F,3.76054166666666
        PRI,2025,P,0.778230137047568
        PRI,2025,F,1.0
        PRT,2025,P,0.534218
        PRT,2025,F,0.88496895841236
        PRY,2025,P,2627.11785121353
        PRY,2025,F,7545.4467553741
        PSE,2025,P,0.63425809329856
        QAT,2025,P,2.0482980288714
        QAT,2025,F,3.64
        ROU,2025,P,1.97967891250975
        ROU,2025,F,4.47053333333333
        RUS,2025,P,29.6122633846497
        RUS,2025,F,83.6525
        RWA,2025,P,385.463038224109
        RWA,2025,F,1428.47827558333
        SAU,2025,P,1.75530234452142
        SAU,2025,F,3.75
        SDN,2022,P,173.565437502227
        SDN,2022,F,546.75885
        SDN,2025,P,1175.58773572252
        SEN,2025,P,208.211053506783
        SEN,2025,F,581.928481040339
        SGP,2025,P,0.790885710223008
        SGP,2025,F,1.30745
        SLB,2025,P,6.23162133063873
        SLB,2025,F,8.32684233252032
        SLE,2023,P,4.792542062985
        SLE,2023,F,21.3048751103817
        SLE,2025,P,5.15883670629659
        SLV,2025,P,0.408953489712557
        SLV,2025,F,1.0
        SMR,2023,P,0.702590229204567
        SMR,2023,F,0.924709622987356
        SOM,2025,P,12115.8880855469
        SRB,2025,P,46.7970682889855
        SRB,2025,F,103.9754
        SSD,2021,P,126.743049621582
        SSD,2021,F,306.354619937276
        STP,2025,P,13.8672557039219
        STP,2025,F,21.7450517869566
        SUR,2025,P,11.6290001939516
        SUR,2025,F,37.2601791666666
        SVK,2025,P,0.512288
        SVK,2025,F,0.88496895841236
        SVN,2025,P,0.558308
        SVN,2025,F,0.88496895841236
        SWE,2025,P,8.548493
        SWE,2025,F,9.82070570950185
        SWZ,2025,P,5.86563643135325
        SWZ,2025,F,17.8889209208377
        SXM,2025,P,1.36183701233079
        SXM,2025,F,1.79
        SYC,2025,P,7.98797394952878
        SYC,2025,F,14.7254562696937
        SYR,2022,P,807.95702765744
        SYR,2022,F,2505.74691085873
        TCA,2024,P,0.986773622391009
        TCA,2024,F,1.0
        TCD,2025,P,204.953276226313
        TCD,2025,F,581.928481040339
        TGO,2025,P,197.415755247599
        TGO,2025,F,581.928481040339
        THA,2025,P,10.0922556843405
        THA,2025,F,32.882809252867
        TJK,2025,P,2.76890578758637
        TJK,2025,F,10.0177083333333
        TKM,2025,P,1.57315223779675
        TLS,2025,P,0.278816251223677
        TLS,2025,F,1.0
        TON,2025,P,1.80792099963135
        TON,2025,F,2.41052686435725
        TTO,2025,P,3.44833404244324
        TTO,2025,F,6.74884660621026
        TUN,2025,P,0.916013551631524
        TUN,2025,F,2.99736666666666
        TUR,2025,P,16.203626
        TUR,2025,F,39.4548130977982
        TUV,2025,P,1.38717699395366
        TUV,2025,F,1.5519978866485
        TZA,2024,P,732.984960136712
        TZA,2024,F,2597.90041666666
        TZA,2025,P,749.533488393139
        UGA,2025,P,1271.51526728309
        UGA,2025,F,3602.98994206813
        UKR,2025,P,12.9353983614283
        UKR,2025,F,41.6890720433333
        URY,2025,P,27.108346862201
        URY,2025,F,41.1909791666666
        USA,2025,P,1.0
        USA,2025,F,1.0
        UZB,2025,P,3670.12629350113
        UZB,2025,F,12579.3943476702
        VCT,2025,P,1.48761704067186
        VCT,2025,F,2.7
        VIR,2022,P,0.890243717259396
        VIR,2022,F,1.0
        VNM,2024,P,6954.97823040608
        VNM,2024,F,24164.8858333333
        VNM,2025,P,6990.87070514029
        VUT,2025,P,107.389043283146
        VUT,2025,F,120.324285714285
        WSM,2025,P,1.75413819197732
        WSM,2025,F,2.79150381915391
        XKX,2025,P,0.362904088534196
        XKX,2025,F,0.887144250370587
        ZAF,2025,P,7.42029658394341
        ZAF,2025,F,17.8887489855833
        ZMB,2025,P,7.56139268212565
        ZMB,2025,F,25.2756892021939
        ZWE,2025,P,14.8477864567247
        ZWE,2025,F,26.5961940841935
        """

    /// Country and the currency the World Bank reports its figures in.
    static let worldBankUnits = """
        ABW,Aruban florin
        AFG,Afghan afghani
        AGO,Angolan kwanza
        ALB,Albanian lek
        AND,Euro
        ARE,U.A.E. dirham
        ARG,Argentine peso
        ARM,Armenian dram
        ASM,U.S. dollar
        ATG,East Caribbean dollar
        AUS,Australian dollar
        AUT,Euro
        AZE,New Azeri manat
        BDI,Burundi franc
        BEL,Euro
        BEN,West African CFA franc
        BFA,West African CFA franc
        BGD,Bangladeshi taka
        BGR,Euro
        BHR,Bahraini dinar
        BHS,Bahamian dollar
        BIH,Bosnia and Herzegovina convertible mark
        BLR,Belarusian rubel
        BLZ,Belize dollar
        BMU,Bermuda dollar
        BOL,Bolivian Boliviano
        BRA,Brazilian real
        BRB,Barbados dollar
        BRN,Brunei dollar
        BTN,Bhutanese ngultrum
        BWA,Botswana pula
        CAF,Central African CFA franc
        CAN,Canadian dollar
        CHE,Swiss franc
        CHI,Pound sterling
        CHL,Chilean peso
        CHN,Chinese yuan
        CIV,West African CFA franc
        CMR,Central African CFA franc
        COD,Congolese franc
        COG,Central African CFA franc
        COL,Colombian peso
        COM,Comorian franc
        CPV,Cabo Verde escudo
        CRI,Costa Rican colon
        CUW,Netherlands Antillean guilder
        CYM,Cayman Islands dollar
        CYP,Euro
        CZE,Czech koruna
        DEU,Euro
        DJI,Djibouti franc
        DMA,East Caribbean dollar
        DNK,Danish krone
        DOM,Dominican peso
        DZA,Algerian dinar
        ECU,U.S. dollar
        EGY,Egyptian pound
        ERI,Eritrean nakfa
        ESP,Euro
        EST,Euro
        ETH,Ethiopian birr
        FIN,Euro
        FJI,Fijian dollar
        FRA,Euro
        FRO,Danish krone
        FSM,U.S. dollar
        GAB,Central African CFA franc
        GBR,Pound sterling
        GEO,Georgian lari
        GHA,New Ghanaian cedi
        GIB,Gibraltar pound
        GIN,Guinean franc
        GMB,Gambian dalasi
        GNB,West African CFA franc
        GNQ,Central African CFA franc
        GRC,Euro
        GRD,East Caribbean dollar
        GRL,Danish krone
        GTM,Guatemalan quetzal
        GUM,U.S. dollar
        GUY,Guyana dollar
        HKG,Hong Kong dollar
        HND,Honduran lempira
        HRV,Euro
        HTI,Haitian gourde
        HUN,Hungarian forint
        IDN,Indonesian rupiah
        IMN,Pound sterling
        IND,Indian rupee
        IRL,Euro
        IRN,Iranian rial
        IRQ,Iraqi dinar
        ISL,Iceland krona
        ISR,Israeli new shekel
        ITA,Euro
        JAM,Jamaican dollar
        JOR,Jordanian dinar
        JPN,Japanese yen
        KAZ,Kazakh tenge
        KEN,Kenyan shilling
        KGZ,Kyrgyz som
        KHM,Cambodian riel
        KIR,Australian dollar
        KNA,East Caribbean dollar
        KOR,Korean won
        KWT,Kuwaiti dinar
        LAO,Lao kip
        LBN,Lebanese pound
        LBR,Liberian dollar
        LBY,Libyan dinar
        LCA,East Caribbean dollar
        LIE,Swiss franc
        LKA,Sri Lankan rupee
        LSO,Lesotho loti
        LTU,Euro
        LUX,Euro
        LVA,Euro
        MAC,Macao pataca
        MAF,Euro
        MAR,Moroccan dirham
        MCO,Euro
        MDA,Moldovan leu
        MDG,Malagasy ariary
        MDV,Maldivian rufiyaa
        MEX,Mexican peso
        MHL,U.S. dollar
        MKD,Macedonian denar
        MLI,West African CFA franc
        MLT,Euro
        MMR,Myanmar kyat
        MNE,Euro
        MNG,Mongolian tugrik
        MNP,U.S. dollar
        MOZ,New Mozambican metical
        MRT,Mauritanian ouguiya
        MUS,Mauritian rupee
        MWI,Malawi kwacha
        MYS,Malaysian ringgit
        NAM,Namibian dollar
        NCL,CFP franc
        NER,West African CFA franc
        NGA,Nigerian naira
        NIC,Nicaraguan gold cordoba
        NLD,Euro
        NOR,Norwegian krone
        NPL,Nepalese rupee
        NRU,Australian dollar
        NZL,New Zealand dollar
        OMN,Omani rial
        PAK,Pakistani rupee
        PAN,Panamanian balboa
        PER,Peruvian new sol
        PHL,Philippine peso
        PLW,U.S. dollar
        PNG,Papua New Guinea kina
        POL,Polish zloty
        PRI,U.S. dollar
        PRT,Euro
        PRY,Paraguayan guarani
        PSE,Israeli new shekel
        PYF,CFP franc
        QAT,Qatari riyal
        ROU,New Romanian leu
        RUS,Russian ruble
        RWA,Rwandan franc
        SAU,Saudi Arabian riyal
        SDN,Sudanese pound
        SEN,West African CFA franc
        SGP,Singapore dollar
        SLB,Solomon Islands dollar
        SLE,Sierra Leonean leone
        SLV,U.S. dollar
        SMR,Euro
        SOM,Somali shilling
        SRB,New Serbian dinar
        SSD,South Sudanese Pound
        STP,São Tomé and Principe dobra
        SUR,Suriname dollar
        SVK,Euro
        SVN,Euro
        SWE,Swedish krona
        SWZ,Swazi lilangeni
        SXM,Netherlands Antillean guilder
        SYC,Seychelles rupee
        SYR,Syrian pound
        TCA,U.S. dollar
        TCD,Central African CFA franc
        TGO,West African CFA franc
        THA,Thai baht
        TJK,Tajik somoni
        TKM,New Turkmen manat
        TLS,U.S. dollar
        TON,Tongan pa'anga
        TTO,Trinidad and Tobago dollar
        TUN,Tunisian dinar
        TUR,New Turkish lira
        TUV,Australian dollar
        TZA,Tanzanian shilling
        UGA,Ugandan shilling
        UKR,Ukrainian hryvnia
        URY,Uruguayan peso
        USA,U.S. dollar
        UZB,Uzbek som
        VCT,East Caribbean dollar
        VIR,U.S. dollar
        VNM,Vietnamese dong
        VUT,Vanuatu vatu
        WSM,Samoan tala
        XKX,Euro
        YEM,Yemeni rial
        ZAF,South African rand
        ZMB,New Zambian kwacha
        ZWE,Zimbabwean Zimbabwe Gold
        """

    /// Date, country, currency, the local price of a Big Mac and the market rate in local currency per US dollar, each country's
    /// newest observation from the last two years. EUZ is the euro area.
    static let bigMacRows = """
        2026-07-01,ARE,AED,19,3.67285
        2026-07-01,ARG,ARS,8700,1472.98605
        2026-07-01,AUS,AUD,8.5,1.42867347667691
        2026-07-01,AZE,AZN,7.25,1.7
        2026-07-01,BHR,BHD,1.8,0.37705
        2026-07-01,BRA,BRL,23.9,5.07935
        2026-07-01,CAN,CAD,8.17,1.40515
        2026-07-01,CHE,CHF,7.3,0.80735
        2026-07-01,CHL,CLP,4990,922.715
        2026-07-01,CHN,CNY,26.5,6.7708
        2026-07-01,COL,COP,25900,3236.28
        2026-07-01,CRI,CRC,3150,450.28
        2026-07-01,CZE,CZK,115,21.1625
        2026-07-01,DNK,DKK,46,6.5366
        2026-07-01,EGY,EGP,145,50.53
        2026-07-01,EUZ,EUR,6.19,0.87439
        2026-07-01,GBR,GBP,5.49,0.74187
        2026-07-01,GTM,GTQ,34,7.6199
        2026-07-01,HKG,HKD,25.5,7.83895
        2026-07-01,HND,HNL,139,26.77
        2026-07-01,HUN,HUF,1660,313.352
        2026-07-01,IDN,IDR,43000,18065
        2026-07-01,IND,INR,236.25,96.26375
        2026-07-01,ISR,ILS,23,2.9993
        2026-07-01,JOR,JOD,2.5,0.709
        2026-07-01,JPN,JPY,500,162.135
        2026-07-01,KOR,KRW,5700,1485.9
        2026-07-01,KWT,KWD,1.4,0.3095
        2026-07-01,LBN,LBP,480000,89550
        2026-07-01,MDA,MDL,80,17.55
        2026-07-01,MEX,MXN,109,17.386
        2026-07-01,MYS,MYR,14.55,4.078
        2026-07-01,NIC,NIO,187,36.6243
        2026-07-01,NOR,NOK,78,9.68565
        2026-07-01,NZL,NZD,8.8,1.71335560695622
        2026-07-01,OMN,OMR,1.53,0.38505
        2026-07-01,PAK,PKR,1080,277.925
        2026-07-01,PER,PEN,16.9,3.3857
        2026-07-01,PHL,PHP,169,61.685
        2026-07-01,POL,PLN,23.5,3.77915
        2026-07-01,QAT,QAR,18,3.641
        2026-07-01,ROU,RON,18.35,4.58165
        2026-07-01,SAU,SAR,19,3.755
        2026-07-01,SGP,SGD,7.45,1.29005
        2026-07-01,SWE,SEK,69,9.63495
        2026-07-01,THA,THB,135,33.62
        2026-07-01,TUR,TRY,325,47.0275
        2026-07-01,TWN,TWD,78,32.1875
        2026-07-01,UKR,UAH,149,44.6702
        2026-07-01,URY,UYU,359,40.165
        2026-07-01,USA,USD,6.22,1
        2026-07-01,VEN,VES,3267,724.8398
        2026-07-01,VNM,VND,76000,26255.5
        2026-07-01,ZAF,ZAR,56.9,16.325
        """

    /// The observations in the shape the published sources use, so they are checked by the same parsers.
    static func data(_ method: PricingMethod) -> PricingIndexData? {
        let fetched = ReportTables.dayFormat.date(from: method == .bigmac ? bigMacUpdated : worldBankUpdated) ?? Date(timeIntervalSince1970: 0)
        switch method {
        case .bigmac:
            let rows = lines(bigMacRows).map { $0.joined(separator: ",") }
            return PricingIndexData(method: .bigmac, data: Data((["date,iso_a3,currency_code,local_price,dollar_ex"] + rows).joined(separator: "\n").utf8), metadata: Data(), fetched: fetched)
        case .ppp:
            let observations: [[String: Any]] = lines(worldBankRows).compactMap { cells in
                guard cells.count == 4, let value = Double(cells[3]) else { return nil }
                return ["indicator": ["id": cells[2] == "F" ? "PA.NUS.FCRF" : "PA.NUS.PPP"], "countryiso3code": cells[0], "date": cells[1], "value": value]
            }
            let variables: [[String: Any]] = worldBankUnits.split(separator: "\n").compactMap { line in
                let parts = line.trimmingCharacters(in: .whitespaces).split(separator: ",", maxSplits: 1).map(String.init)
                return parts.count == 2 ? ["id": parts[0], "metatype": [["id": "CurrencyUnit", "value": parts[1]]]] : nil
            }
            guard let data = try? JSONSerialization.data(withJSONObject: [["page": 1, "pages": 1], observations] as [Any]),
                  let metadata = try? JSONSerialization.data(withJSONObject: ["page": 1, "pages": 1, "source": [["concept": [["variable": variables]]]]] as [String: Any]) else { return nil }
            return PricingIndexData(method: .ppp, data: data, metadata: metadata, fetched: fetched)
        default: return nil
        }
    }

    private static func lines(_ text: String) -> [[String]] {
        text.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces).split(separator: ",").map(String.init) }
    }
}
