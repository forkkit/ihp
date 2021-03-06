{-|
Module: IHP.IDE.SchemaDesigner.Types
Description: Parser for Application/Schema.sql
Copyright: (c) digitally induced GmbH, 2020
-}
module IHP.IDE.SchemaDesigner.Parser
( parseSchemaSql
, schemaFilePath
, parseDDL
, expression
, sqlType
) where

import IHP.Prelude
import IHP.IDE.SchemaDesigner.Types
import qualified Prelude
import qualified Data.Text as Text
import qualified Data.Text.IO as Text
import Text.Megaparsec
import Data.Void
import Text.Megaparsec.Char
import qualified Text.Megaparsec.Char.Lexer as Lexer
import Data.Char
import IHP.IDE.SchemaDesigner.Compiler (compileSql)

schemaFilePath = "Application/Schema.sql"

parseSchemaSql :: IO (Either ByteString [Statement])
parseSchemaSql = do
    schemaSql <- Text.readFile schemaFilePath
    let result = runParser parseDDL (cs schemaFilePath) schemaSql
    case result of
        Left error -> pure (Left (cs $ errorBundlePretty error))
        Right r -> pure (Right r)

type Parser = Parsec Void Text

spaceConsumer :: Parser ()
spaceConsumer = Lexer.space
    space1
    (Lexer.skipLineComment "//")
    (Lexer.skipBlockComment "/*" "*/")

lexeme :: Parser a -> Parser a
lexeme = Lexer.lexeme spaceConsumer

symbol :: Text -> Parser Text
symbol = Lexer.symbol spaceConsumer

symbol' :: Text -> Parser Text
symbol' = Lexer.symbol' spaceConsumer

stringLiteral :: Parser String
stringLiteral = char '\'' *> manyTill Lexer.charLiteral (char '\'')

parseDDL :: Parser [Statement]
parseDDL = manyTill statement eof
    
statement = do
    s <- try createExtension <|> try createTable <|> createEnumType <|> addConstraint <|> comment
    space
    pure s


createExtension = do
    lexeme "CREATE"
    lexeme "EXTENSION"
    ifNotExists <- isJust <$> optional (lexeme "IF" >> lexeme "NOT" >> lexeme "EXISTS")
    name <- cs <$> (char '"' *> manyTill Lexer.charLiteral (char '"'))
    char ';'
    pure CreateExtension { name, ifNotExists = True }

createTable = do
    lexeme "CREATE"
    lexeme "TABLE"
    optional do
        lexeme "public"
        char '.'
    name <- identifier
    columns <- between (char '(' >> space) (char ')' >> space) (column `sepBy` (char ',' >> space))
    char ';'
    pure CreateTable { name, columns }

createEnumType = do
    lexeme "CREATE"
    lexeme "TYPE"
    name <- identifier
    lexeme "AS"
    lexeme "ENUM"
    values <- between (char '(' >> space) (char ')' >> space) (textExpr' `sepBy` (char ',' >> space))
    char ';'
    pure CreateEnumType { name, values }

addConstraint = do
    lexeme "ALTER"
    lexeme "TABLE"
    tableName <- identifier
    lexeme "ADD"
    lexeme "CONSTRAINT"
    constraintName <- identifier
    constraint <- parseConstraint
    char ';'
    pure AddConstraint { tableName, constraintName, constraint }

parseConstraint = do
    lexeme "FOREIGN"
    lexeme "KEY"
    columnName <- between (char '(' >> space) (char ')' >> space) identifier
    lexeme "REFERENCES"
    referenceTable <- identifier
    referenceColumn <- optional $ between (char '(' >> space) (char ')' >> space) identifier
    onDelete <- optional do
        lexeme "ON"
        lexeme "DELETE"
        parseOnDelete
    pure ForeignKeyConstraint { columnName, referenceTable, referenceColumn, onDelete }

parseOnDelete = choice
        [ (lexeme "NO" >> lexeme "ACTION") >> pure NoAction
        , (lexeme "RESTRICT" >> pure Restrict)
        , (lexeme "SET" >> lexeme "NULL") >> pure SetNull
        , (lexeme "CASCADE" >> pure Cascade)
        ]

column = do
    name <- identifier
    columnType <- sqlType
    space
    defaultValue <- optional do
        lexeme "DEFAULT"
        expression
    primaryKey <- isJust <$> optional (lexeme "PRIMARY" >> lexeme "KEY")
    notNull <- isJust <$> optional (lexeme "NOT" >> lexeme "NULL")
    isUnique <- isJust <$> optional (lexeme "UNIQUE")
    pure Column { name, columnType, primaryKey, defaultValue, notNull, isUnique }

sqlType :: Parser PostgresType
sqlType = choice
        [ uuid
        , text
        , bigint
        , int
        , bool
        , timestampZ
        , real
        , double
        , date
        , binary
        , time
        , customType
        ]
            where
                uuid = do
                    try (symbol' "UUID")
                    pure PUUID

                text = do
                    try (symbol' "TEXT")
                    pure PText

                int = do
                    try (symbol' "INTEGER") <|> try (symbol' "INT4") <|> try (symbol' "INT")
                    pure PInt

                bigint = do
                    try (symbol' "BIGINT") <|> try (symbol' "INT8")
                    pure PBigInt

                bool = do
                    try (symbol' "BOOLEAN") <|> try (symbol' "BOOL")
                    pure PBoolean

                timestampZ = do
                    try (symbol' "TIMESTAMPZ") <|> (symbol' "TIMESTAMP" >> symbol' "WITH" >> symbol' "TIME" >> symbol' "ZONE")
                    pure PTimestampWithTimezone

                real = do
                    try (symbol' "REAL") <|> try (symbol' "FLOAT4")
                    pure PReal

                double = do
                    try (symbol' "DOUBLE PRECISION") <|> try (symbol' "FLOAT8")
                    pure PDouble

                date = do
                    try (symbol' "DATE")
                    pure PDate

                binary = do
                    try (symbol' "BINARY")
                    pure PBinary

                time = do
                    try (symbol' "TIME")
                    pure PTime

                customType = do
                    theType <- try (takeWhile1P (Just "Custom type") (\c -> isAlphaNum c || c == '_'))
                    pure (PCustomType theType)

expression :: Parser Expression
expression = do
    e <- try callExpr <|> varExpr <|> textExpr 
    space 
    pure e

varExpr :: Parser Expression
varExpr = VarExpression <$> identifier

callExpr :: Parser Expression
callExpr = do
    func <- identifier
    args <- between (char '(') (char ')') (expression `sepBy` char ',')
    pure (CallExpression func args)

textExpr :: Parser Expression
textExpr = TextExpression <$> textExpr'

textExpr' :: Parser Text
textExpr' = cs <$> (char '\'' *> manyTill Lexer.charLiteral (char '\''))

identifier :: Parser Text
identifier = do
    i <- (between (char '"') (char '"') (takeWhile1P Nothing (\c -> c /= '"'))) <|> takeWhile1P (Just "identifier") (\c -> isAlphaNum c || c == '_')
    space
    pure i

comment = do
    lexeme "--" <?> "Line comment"
    content <- takeWhileP Nothing (/= '\n')
    pure Comment { content }

